-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Step 17 (HR Dev Framework): Audit log retention + immutable
--
-- ตาม HR Development Framework Step 17:
--   - Immutable: WORM (append-only — ห้าม UPDATE/DELETE)
--   - Retention: ≥ 3 ปี (PDPA / Labour Law requirement)
--
-- ปัญหาเดิม (audit-log.sql):
--   - RLS อนุญาตให้ admin SELECT ได้ (ถูกต้อง)
--   - แต่ไม่มี policy ห้าม UPDATE/DELETE → ถ้า service_role bypass ได้ตามใจ
--   - ไม่มี retention strategy → log จะโตเรื่อยๆ จนกระทบ DB free plan (500MB)
--
-- การแก้:
--   1. เพิ่ม policy ห้าม UPDATE/DELETE บน audit_log ของ authenticated
--      (trigger ที่เรียกใน SECURITY DEFINER ยังเขียน INSERT ได้ปกติ)
--   2. สร้าง RPC purge_old_audit_logs() — เรียก manually หรือผ่าน pg_cron
--      ลบ log เก่ากว่า 3 ปี (1095 วัน)
--   3. แนะนำให้ admin export log ก่อน purge → cold storage (PDPA)
--
-- รันใน Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════

-- 1. ห้าม UPDATE/DELETE audit_log ผ่าน authenticated (immutable WORM)
DROP POLICY IF EXISTS "no_update" ON public.audit_log;
DROP POLICY IF EXISTS "no_delete" ON public.audit_log;

-- ห้าม UPDATE
CREATE POLICY "no_update" ON public.audit_log
  FOR UPDATE TO authenticated
  USING (false)
  WITH CHECK (false);

-- ห้าม DELETE (ยกเว้น purge function ที่ใช้ SECURITY DEFINER)
CREATE POLICY "no_delete" ON public.audit_log
  FOR DELETE TO authenticated
  USING (false);

-- 2. RPC purge — admin เท่านั้นเรียกได้
CREATE OR REPLACE FUNCTION public.purge_old_audit_logs(
  p_days INTEGER DEFAULT 1095  -- 3 ปี default
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
  v_cutoff TIMESTAMPTZ;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'เฉพาะ admin เรียกได้';
  END IF;

  IF p_days < 365 THEN
    RAISE EXCEPTION 'retention ขั้นต่ำ 365 วัน (PDPA + Labour Law)';
  END IF;

  v_cutoff := now() - (p_days || ' days')::interval;

  DELETE FROM public.audit_log WHERE ts < v_cutoff;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- เขียน meta log ลงตัวเองว่ามีการ purge (ไว้ track)
  INSERT INTO public.audit_log (
    user_id, user_email, user_role,
    action, table_name, record_id, new_data
  ) VALUES (
    auth.uid(),
    (SELECT email FROM auth.users WHERE id = auth.uid()),
    'admin',
    'PURGE_AUDIT',
    'audit_log',
    NULL,
    jsonb_build_object(
      'deleted_rows', v_count,
      'cutoff_ts',    v_cutoff,
      'retention_days', p_days
    )
  );

  RETURN jsonb_build_object(
    'deleted',         v_count,
    'cutoff',          v_cutoff,
    'retention_days',  p_days
  );
END $$;

GRANT EXECUTE ON FUNCTION public.purge_old_audit_logs(INTEGER) TO authenticated;

-- 3. ฟังก์ชัน export — admin ดึง log เก่าออกก่อน purge (PDPA compliance)
CREATE OR REPLACE FUNCTION public.export_old_audit_logs(
  p_days INTEGER DEFAULT 1095,
  p_limit INTEGER DEFAULT 10000
)
RETURNS SETOF public.audit_log
LANGUAGE PLPGSQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'เฉพาะ admin เรียกได้';
  END IF;

  RETURN QUERY
  SELECT * FROM public.audit_log
  WHERE ts < now() - (p_days || ' days')::interval
  ORDER BY ts ASC
  LIMIT p_limit;
END $$;

GRANT EXECUTE ON FUNCTION public.export_old_audit_logs(INTEGER, INTEGER) TO authenticated;

-- 4. ตรวจ policy + report สถานะ
DO $$
DECLARE
  v_policy RECORD;
  v_total_rows BIGINT;
  v_oldest TIMESTAMPTZ;
  v_db_size_mb NUMERIC;
BEGIN
  SELECT COUNT(*), MIN(ts) INTO v_total_rows, v_oldest FROM public.audit_log;

  RAISE NOTICE '─── audit_log policies ───';
  FOR v_policy IN
    SELECT policyname, cmd FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'audit_log'
    ORDER BY cmd, policyname
  LOOP
    RAISE NOTICE '  [%] %', v_policy.cmd, v_policy.policyname;
  END LOOP;

  RAISE NOTICE '─── audit_log stats ───';
  RAISE NOTICE '  total rows: %', v_total_rows;
  RAISE NOTICE '  oldest:     %', v_oldest;
END $$;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Step 17 (audit retention) รัน เสร็จแล้ว';
  RAISE NOTICE '   - audit_log: ห้าม UPDATE/DELETE จาก authenticated (immutable)';
  RAISE NOTICE '   - RPC purge_old_audit_logs(days) → ลบ log เก่า ≥ 365 วัน';
  RAISE NOTICE '   - RPC export_old_audit_logs(days, limit) → export ก่อน purge';
  RAISE NOTICE '   ⚠️ Free plan ไม่มี pg_cron — ต้องเรียก purge manually ทุก 6 เดือน';
  RAISE NOTICE '   📌 PDPA: ก่อน purge ให้ export → backup external (S3/Drive)';
END $$;
