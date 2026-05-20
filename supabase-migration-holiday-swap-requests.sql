-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Holiday Swap Approval Workflow
-- ระบบขออนุมัติเปลี่ยนวันหยุดประเพณี (ใช้ chain เดียวกับการลา)
--
-- Flow:
--   1) HR/Manager สร้างคำขอเปลี่ยนวันหยุดประเพณี → status='pending'
--   2) Approver (chain: หัวสาขา → AM → HR → admin) อนุมัติ/ปฏิเสธ
--   3) เมื่ออนุมัติ trigger update calendar_items.swap_to_date + swap_note
--   4) เมื่อยกเลิกหลังอนุมัติ → trigger เคลียร์ swap_to_date กลับ
--
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ─── TABLE ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.holiday_swap_requests (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  calendar_item_id  UUID NOT NULL REFERENCES public.calendar_items(id) ON DELETE CASCADE,
  employee_id       TEXT NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,  -- requester's employee (สำหรับ chain อนุมัติ)
  swap_to_date      DATE NOT NULL,                  -- วันที่ขอหยุดชดเชย
  reason            TEXT,                            -- เหตุผล เช่น "ยกเว้นทางกฎหมาย"
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled')),
  requested_by      UUID,                            -- user_id ของผู้ยื่น
  requested_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_by       UUID,                            -- user_id ของผู้อนุมัติ/ปฏิเสธ
  approved_at       TIMESTAMPTZ,
  approver_note     TEXT,
  cancelled_at      TIMESTAMPTZ,
  cancelled_by      UUID,
  cancel_reason     TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_swap_req_calendar  ON public.holiday_swap_requests(calendar_item_id);
CREATE INDEX IF NOT EXISTS idx_swap_req_employee  ON public.holiday_swap_requests(employee_id);
CREATE INDEX IF NOT EXISTS idx_swap_req_status    ON public.holiday_swap_requests(status);
CREATE INDEX IF NOT EXISTS idx_swap_req_pending   ON public.holiday_swap_requests(employee_id) WHERE status = 'pending';

-- ─── RLS ────────────────────────────────────────────────
ALTER TABLE public.holiday_swap_requests ENABLE ROW LEVEL SECURITY;

-- เคลียร์ policies เก่า (รองรับชื่อทั้งเดิม + ใหม่ — รันซ้ำได้)
DROP POLICY IF EXISTS "swap_read_scoped"   ON public.holiday_swap_requests;
DROP POLICY IF EXISTS "swap_insert_self_or_admin"   ON public.holiday_swap_requests;
DROP POLICY IF EXISTS "swap_update_admin_or_approver_or_own_pending" ON public.holiday_swap_requests;
DROP POLICY IF EXISTS "swap_delete_hr_or_admin"     ON public.holiday_swap_requests;

-- SELECT: ใช้ scope เดียวกับ leave_requests
CREATE POLICY "swap_read_scoped" ON public.holiday_swap_requests
  FOR SELECT TO authenticated
  USING (
    public.is_hr_or_admin()
    OR public.current_user_role() = 'operation_manager'
    OR public.can_approve_leave_for(employee_id)
    OR employee_id = public.current_user_employee_id()
    OR EXISTS (
      SELECT 1 FROM public.employees e
      WHERE e.id = holiday_swap_requests.employee_id
        AND (
          (public.current_user_role() = 'branch_manager'
            AND e.branch = public.current_user_branch())
          OR (public.current_user_role() = 'area_manager'
            AND e.branch = ANY(public.current_user_managed_branches()))
        )
    )
  );

-- INSERT: HR/admin ส่งได้ทุกอย่าง, ผู้ใช้อื่นส่งของตัวเอง + บังคับ pending
CREATE POLICY "swap_insert_self_or_admin" ON public.holiday_swap_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_hr_or_admin()
    OR (
      status = 'pending'
      AND approved_by IS NULL
      AND approved_at IS NULL
      AND employee_id IN (SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid())
    )
  );

-- UPDATE: HR/admin หรือ approver หรือ เจ้าของ pending
CREATE POLICY "swap_update_admin_or_approver_or_own_pending" ON public.holiday_swap_requests
  FOR UPDATE TO authenticated
  USING (
    public.is_hr_or_admin()
    OR public.can_approve_leave_for(employee_id)
    OR (
      status = 'pending'
      AND employee_id IN (SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid())
    )
  )
  WITH CHECK (
    public.is_hr_or_admin()
    OR public.can_approve_leave_for(employee_id)
    OR (
      status IN ('pending', 'cancelled')
      AND employee_id IN (SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid())
    )
  );

-- DELETE: HR/admin เท่านั้น
CREATE POLICY "swap_delete_hr_or_admin" ON public.holiday_swap_requests
  FOR DELETE TO authenticated
  USING (public.is_hr_or_admin());

-- ─── Auto-update updated_at ─────────────────────────────
CREATE OR REPLACE FUNCTION public.set_swap_req_updated_at()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_swap_req_updated_at ON public.holiday_swap_requests;
CREATE TRIGGER trg_swap_req_updated_at
  BEFORE UPDATE ON public.holiday_swap_requests
  FOR EACH ROW EXECUTE FUNCTION public.set_swap_req_updated_at();

-- ─── Apply approved swap → calendar_items ───────────────
-- เมื่อ status เปลี่ยนจาก pending → approved → set calendar_items.swap_to_date
-- เมื่อ status เปลี่ยนจาก approved → cancelled/rejected → เคลียร์ calendar_items.swap_to_date
-- (กรณีคำขออื่นอยู่ pending — admin/HR ต้องอนุมัติทีละคำขอ; ระบบจะ override ค่าล่าสุด)
CREATE OR REPLACE FUNCTION public.apply_holiday_swap()
RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER AS $$
BEGIN
  -- INSERT/UPDATE → approved: apply
  IF (NEW.status = 'approved') AND (OLD.status IS DISTINCT FROM 'approved') THEN
    UPDATE public.calendar_items
       SET swap_to_date = NEW.swap_to_date,
           swap_note    = NEW.reason
     WHERE id = NEW.calendar_item_id;
  END IF;

  -- UPDATE: approved → cancelled/rejected: revert (เคลียร์ swap)
  IF (OLD.status = 'approved') AND (NEW.status IN ('cancelled','rejected','pending')) THEN
    -- ตรวจว่ามีคำขออื่นที่ approved สำหรับ holiday เดียวกันไหม
    -- ถ้ามี → ใช้ค่าจากคำขออื่น (ล่าสุด); ถ้าไม่มี → เคลียร์
    UPDATE public.calendar_items ci
       SET swap_to_date = sub.swap_to_date,
           swap_note    = sub.reason
      FROM (
        SELECT swap_to_date, reason
          FROM public.holiday_swap_requests
         WHERE calendar_item_id = NEW.calendar_item_id
           AND status = 'approved'
           AND id <> NEW.id
         ORDER BY approved_at DESC NULLS LAST
         LIMIT 1
      ) sub
     WHERE ci.id = NEW.calendar_item_id;

    -- ถ้าไม่มี row ใน sub → UPDATE FROM จะไม่ทำงาน — fallback เคลียร์ตรงๆ
    IF NOT EXISTS (
      SELECT 1 FROM public.holiday_swap_requests
       WHERE calendar_item_id = NEW.calendar_item_id
         AND status = 'approved'
         AND id <> NEW.id
    ) THEN
      UPDATE public.calendar_items
         SET swap_to_date = NULL,
             swap_note    = NULL
       WHERE id = NEW.calendar_item_id;
    END IF;
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_apply_holiday_swap ON public.holiday_swap_requests;
CREATE TRIGGER trg_apply_holiday_swap
  AFTER INSERT OR UPDATE ON public.holiday_swap_requests
  FOR EACH ROW EXECUTE FUNCTION public.apply_holiday_swap();

-- ─── Realtime ───────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND tablename = 'holiday_swap_requests') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.holiday_swap_requests;
  END IF;
END $$;

-- ─── Audit trigger (ผูกกับ audit_trigger_fn ถ้ามี) ───────
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'audit_trigger_fn' AND pronamespace = 'public'::regnamespace) THEN
    DROP TRIGGER IF EXISTS audit_trigger ON public.holiday_swap_requests;
    CREATE TRIGGER audit_trigger
      AFTER INSERT OR UPDATE OR DELETE ON public.holiday_swap_requests
      FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_fn();
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════
-- หมายเหตุการใช้งาน:
--
-- 1. ผู้ใช้สิทธิ์ HR/manager+ ยื่นคำขอเปลี่ยนวันหยุด
--    INSERT (calendar_item_id, employee_id=ตัวเอง, swap_to_date, reason)
--    → status='pending' โดยอัตโนมัติ
--
-- 2. Approver (จาก leave_approver_for) เห็นคำขอใน "รออนุมัติ"
--    → UPDATE status='approved'/'rejected' + approver_note
--
-- 3. เมื่อ approved trigger จะ apply swap_to_date ลง calendar_items อัตโนมัติ
--    → ทุก client ที่ subscribe จะเห็นการเปลี่ยนแปลงผ่าน realtime
--
-- 4. ถ้ายกเลิกหลังอนุมัติแล้ว trigger จะ revert calendar_items
--    (ใช้คำขอ approved ล่าสุดถัดไป หรือ NULL ถ้าไม่มี)
-- ═══════════════════════════════════════════════════════════
