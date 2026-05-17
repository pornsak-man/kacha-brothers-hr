-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Audit Log + RLS Hardening
-- ─────────────────────────────────────────────────────────
-- 1) ตาราง audit_log — บันทึกทุกการเปลี่ยนแปลง (INSERT/UPDATE/DELETE)
-- 2) Trigger ติดอัตโนมัติบน sensitive tables
-- 3) RLS: ดู audit_log ได้เฉพาะ admin (SECURITY DEFINER → bypass user RLS)
-- 4) Tighten salary_history → admin-only read
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ─── AUDIT LOG TABLE ───
CREATE TABLE IF NOT EXISTS public.audit_log (
  id          BIGSERIAL PRIMARY KEY,
  ts          TIMESTAMPTZ NOT NULL DEFAULT now(),
  user_id     UUID,
  user_email  TEXT,
  user_role   TEXT,
  action      TEXT NOT NULL,         -- INSERT / UPDATE / DELETE
  table_name  TEXT NOT NULL,
  record_id   TEXT,
  old_data    JSONB,
  new_data    JSONB
);
CREATE INDEX IF NOT EXISTS idx_audit_log_ts         ON public.audit_log(ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_table      ON public.audit_log(table_name);
CREATE INDEX IF NOT EXISTS idx_audit_log_user       ON public.audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_record     ON public.audit_log(table_name, record_id);

-- ─── RLS: audit_log อ่านได้เฉพาะ admin, เขียนได้เฉพาะ trigger (SECURITY DEFINER) ───
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_admin_only" ON public.audit_log;
DROP POLICY IF EXISTS "no_user_write"  ON public.audit_log;
CREATE POLICY "read_admin_only" ON public.audit_log FOR SELECT TO authenticated
  USING (public.is_admin());
-- ห้าม user INSERT/UPDATE/DELETE ตรงๆ (จะมีเฉพาะ trigger เท่านั้น)

-- ─── RLS HARDENING: salary_history → admin-only read (sensitive — เงินเดือนเก่า/ใหม่) ───
DROP POLICY IF EXISTS "read_authenticated" ON public.salary_history;
CREATE POLICY "read_admin_only" ON public.salary_history FOR SELECT TO authenticated
  USING (public.is_admin());

-- ─── TRIGGER FUNCTION ───
-- SECURITY DEFINER ทำให้ trigger เขียน audit_log ได้แม้ user ไม่มีสิทธิ์
CREATE OR REPLACE FUNCTION public.audit_trigger_fn()
RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER AS $$
DECLARE
  v_user_id    UUID;
  v_user_email TEXT;
  v_user_role  TEXT;
  v_record_id  TEXT;
  v_old        JSONB;
  v_new        JSONB;
BEGIN
  -- ดึง user context (จาก JWT)
  BEGIN
    v_user_id := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    v_user_id := NULL;
  END;
  IF v_user_id IS NOT NULL THEN
    SELECT email INTO v_user_email FROM auth.users WHERE id = v_user_id;
    SELECT role INTO v_user_role FROM public.user_profiles WHERE user_id = v_user_id;
  END IF;

  -- ดึง record id (ทุก table ที่เรา audit มี column id)
  IF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD);
    v_new := NULL;
    BEGIN v_record_id := (to_jsonb(OLD)->>'id'); EXCEPTION WHEN OTHERS THEN v_record_id := NULL; END;
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    BEGIN v_record_id := (to_jsonb(NEW)->>'id'); EXCEPTION WHEN OTHERS THEN v_record_id := NULL; END;
  ELSE  -- INSERT
    v_old := NULL;
    v_new := to_jsonb(NEW);
    BEGIN v_record_id := (to_jsonb(NEW)->>'id'); EXCEPTION WHEN OTHERS THEN v_record_id := NULL; END;
  END IF;

  INSERT INTO public.audit_log (
    user_id, user_email, user_role,
    action, table_name, record_id, old_data, new_data
  ) VALUES (
    v_user_id, v_user_email, v_user_role,
    TG_OP, TG_TABLE_NAME, v_record_id, v_old, v_new
  );

  RETURN COALESCE(NEW, OLD);
END $$;

-- ─── ATTACH TRIGGERS — เฉพาะ tables ที่มีค่า audit ───
-- ใช้ helper macro: drop ก่อน create เพื่อ idempotent
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'employees',          -- การเพิ่ม/แก้ไข/ลบพนักงาน
    'salary_history',     -- การปรับค่าจ้าง/ตำแหน่ง/สาขา
    'applicants',         -- ใบสมัคร
    'loans',              -- การกู้
    'advances',           -- เบิกเงินล่วงหน้า
    'allowances',         -- เบี้ยเลี้ยง
    'evaluations',        -- การประเมิน
    'uniform_requests',   -- คำขอจัดชุด
    'uniform_issues',     -- การจัดส่งชุด
    'uniform_items',      -- master ชุด + stock
    'branches',           -- master สาขา
    'departments',        -- master ฝ่าย
    'position_levels',    -- master ตำแหน่ง
    'user_profiles'       -- การเปลี่ยน role
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS audit_trigger ON public.%I', t);
    EXECUTE format(
      'CREATE TRIGGER audit_trigger AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_fn()',
      t
    );
  END LOOP;
END $$;

-- ─── REALTIME (เพื่อ refresh page audit อัตโนมัติ) ───
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'audit_log'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.audit_log;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════
-- USAGE
-- ─────────────────────────────────────────────────────────
-- ดู log 100 รายการล่าสุด:
--   SELECT * FROM audit_log ORDER BY ts DESC LIMIT 100;
-- ดูการแก้ไขเงินเดือนของพนักงาน 1001:
--   SELECT * FROM audit_log
--   WHERE table_name = 'salary_history' AND new_data->>'employee_id' = '1001'
--   ORDER BY ts DESC;
-- ดูการลบทั้งหมด:
--   SELECT * FROM audit_log WHERE action = 'DELETE' ORDER BY ts DESC;
-- ═══════════════════════════════════════════════════════════
