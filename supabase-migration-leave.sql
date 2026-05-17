-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Leave Management
-- ระบบการลางาน 7 ประเภท ตามกฎหมายแรงงานไทย
--   • ลากิจ 3 วัน / ปี
--   • ลาป่วย 30 วัน / ปี
--   • ลาคลอดบุตร (หญิง) 98 วัน (พ.ร.บ.คุ้มครองแรงงาน §41 — 2018 amendment)
--   • ลาคลอดบุตร (ชาย) 15 วัน
--   • ลาพักร้อน — 6 วัน เมื่อทำงานครบ 1 ปี เพิ่มปีละ 1 วัน สูงสุด 12 วัน (ห้ามข้ามปี)
--   • ลาบวช 15 วัน (ชายเท่านั้น)
--   • ลารับราชการทหาร 60 วัน (พ.ร.บ.คุ้มครองแรงงาน §35)
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.leave_requests (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  employee_id     TEXT NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  leave_type      TEXT NOT NULL CHECK (leave_type IN ('personal','sick','maternity','paternity','vacation','ordination','military')),
  start_date      DATE NOT NULL,
  end_date        DATE NOT NULL,
  days            NUMERIC(5,1) NOT NULL CHECK (days > 0),  -- รองรับครึ่งวัน เช่น 0.5, 1.5
  reason          TEXT,
  status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled')),
  requested_by    UUID,           -- user_id ของผู้กรอก
  requested_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_by     UUID,           -- user_id ของ admin ผู้อนุมัติ/ปฏิเสธ
  approved_at     TIMESTAMPTZ,
  approver_note   TEXT,
  cancelled_at    TIMESTAMPTZ,
  cancelled_by    UUID,
  cancel_reason   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_leave_date_order CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS idx_leave_emp     ON public.leave_requests(employee_id);
CREATE INDEX IF NOT EXISTS idx_leave_status  ON public.leave_requests(status);
CREATE INDEX IF NOT EXISTS idx_leave_dates   ON public.leave_requests(start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_leave_type    ON public.leave_requests(leave_type);
CREATE INDEX IF NOT EXISTS idx_leave_year    ON public.leave_requests(employee_id, leave_type, (EXTRACT(YEAR FROM start_date)));

-- ─── RLS ─────────────────────────────────────────────────
ALTER TABLE public.leave_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_own_or_admin"        ON public.leave_requests;
DROP POLICY IF EXISTS "insert_self_or_admin"     ON public.leave_requests;
DROP POLICY IF EXISTS "update_admin_or_own_pending" ON public.leave_requests;
DROP POLICY IF EXISTS "delete_admin"             ON public.leave_requests;

-- viewer เห็นเฉพาะของตัวเอง (link ผ่าน user_profiles.employee_id), admin เห็นทุกคน
CREATE POLICY "read_own_or_admin" ON public.leave_requests FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR employee_id IN (SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid())
  );

-- viewer ส่งคำขอของตัวเอง, admin ส่งให้ใครก็ได้
CREATE POLICY "insert_self_or_admin" ON public.leave_requests FOR INSERT TO authenticated
  WITH CHECK (
    public.is_admin()
    OR employee_id IN (SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid())
  );

-- admin update ทุกอย่าง, viewer update/ยกเลิกได้เฉพาะของตัวเองที่ยัง pending
CREATE POLICY "update_admin_or_own_pending" ON public.leave_requests FOR UPDATE TO authenticated
  USING (
    public.is_admin()
    OR (status = 'pending' AND employee_id IN (SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid()))
  );

CREATE POLICY "delete_admin" ON public.leave_requests FOR DELETE TO authenticated
  USING (public.is_admin());

-- ─── Auto-update updated_at ─────────────────────────────
CREATE OR REPLACE FUNCTION public.set_leave_updated_at()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_leave_updated_at ON public.leave_requests;
CREATE TRIGGER trg_leave_updated_at BEFORE UPDATE ON public.leave_requests
  FOR EACH ROW EXECUTE FUNCTION public.set_leave_updated_at();

-- ─── Realtime ───────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND tablename = 'leave_requests') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.leave_requests;
  END IF;
END $$;

-- ─── Audit trigger (ผูกกับ audit_trigger_fn ถ้ามี migration audit-log แล้ว) ───
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'audit_trigger_fn' AND pronamespace = 'public'::regnamespace) THEN
    DROP TRIGGER IF EXISTS audit_trigger ON public.leave_requests;
    CREATE TRIGGER audit_trigger AFTER INSERT OR UPDATE OR DELETE ON public.leave_requests
      FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_fn();
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
