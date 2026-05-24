-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Anti-tamper trigger สำหรับ leave_requests
--
-- ปัญหา: RLS policy "update_admin_or_approver_or_own_pending" อนุญาต owner
--        update row ของตัวเอง ขณะ status='pending' — แต่ไม่ block ว่าจะแก้ field ไหน
--        → พนักงานเปิด DevTools console + Supabase SDK สามารถ tamper:
--          await DB.client.from('leave_requests').update({days: 30}).eq('id', '...')
--          → โควต้าวันลาผิดได้ ถ้า HR approve โดยไม่ตรวจ
--
-- แก้: BEFORE UPDATE trigger ที่ตรวจ caller:
--      - HR/admin/approver/service_role → bypass (ทำได้ทุกอย่างตามเดิม)
--      - Owner → อนุญาตเฉพาะ status pending→cancelled (และห้ามแตะ field อื่น)
--               ถ้าจะแก้ field อื่น ต้องผ่านฟอร์ม (ที่ recreate row ผ่าน save → upsert)
--
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — CREATE OR REPLACE + DROP IF EXISTS)
-- ═══════════════════════════════════════════════════════════
-- ROLLBACK (paste เพื่อ undo):
--   DROP TRIGGER IF EXISTS trg_leave_request_anti_tamper ON public.leave_requests;
--   DROP FUNCTION IF EXISTS public.guard_leave_request_owner_tamper();
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.guard_leave_request_owner_tamper()
RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_is_owner BOOLEAN;
BEGIN
  -- bypass 1: service_role (admin RPC, server-side jobs)
  IF current_setting('request.jwt.claim.role', true) = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- bypass 2: HR/admin/approver — ปล่อยผ่าน (เป็นคนที่อนุมัติ/แก้แทน)
  IF public.is_hr_or_admin() OR public.can_approve_leave_for(NEW.employee_id) THEN
    RETURN NEW;
  END IF;

  -- เช็คว่าเป็น owner ของ row นี้ไหม
  v_is_owner := EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE user_id = auth.uid() AND employee_id = OLD.employee_id
  );

  IF NOT v_is_owner THEN
    -- non-owner non-HR non-approver — ไม่ควรถึงตรงนี้ (RLS น่าจะ block ก่อน) แต่ defensive
    RAISE EXCEPTION 'ไม่มีสิทธิ์แก้คำขอลาของผู้อื่น';
  END IF;

  -- === ถึงตรงนี้ = caller เป็น OWNER ของ row ===

  -- ห้ามเปลี่ยน employee_id (กัน reassign คำขอไปคนอื่น)
  IF NEW.employee_id IS DISTINCT FROM OLD.employee_id THEN
    RAISE EXCEPTION 'ไม่มีสิทธิ์เปลี่ยน employee_id ของคำขอลา';
  END IF;

  -- กรณี 1: ยกเลิก (pending → cancelled) — อนุญาต แต่ห้ามแก้ field อื่นพร้อมกัน
  IF OLD.status = 'pending' AND NEW.status = 'cancelled' THEN
    IF NEW.days IS DISTINCT FROM OLD.days
       OR NEW.start_date IS DISTINCT FROM OLD.start_date
       OR NEW.end_date IS DISTINCT FROM OLD.end_date
       OR NEW.leave_type IS DISTINCT FROM OLD.leave_type
       OR NEW.reason IS DISTINCT FROM OLD.reason
       OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
       OR NEW.approver_note IS DISTINCT FROM OLD.approver_note THEN
      RAISE EXCEPTION 'ยกเลิกคำขอได้อย่างเดียว — ห้ามแก้รายละเอียดอื่นพร้อมกัน';
    END IF;
    RETURN NEW;
  END IF;

  -- กรณี 2: คงสถานะ pending — อนุญาตแก้ field ของตัวเอง (ผ่านฟอร์ม)
  -- แต่ห้ามแตะ approver fields (กัน fake approval)
  IF OLD.status = 'pending' AND NEW.status = 'pending' THEN
    IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
       OR NEW.approver_note IS DISTINCT FROM OLD.approver_note THEN
      RAISE EXCEPTION 'ไม่มีสิทธิ์แก้ฟิลด์ของผู้อนุมัติ (approved_by/at/note)';
    END IF;
    -- ตรวจ days สอดคล้องกับ start/end (defense-in-depth — UI lock แล้วแต่ trust nothing)
    -- ห้ามใส่ days เกินช่วงวันที่ที่เลือก
    DECLARE
      v_calendar_days INTEGER;
    BEGIN
      v_calendar_days := (NEW.end_date - NEW.start_date) + 1;
      IF NEW.days IS NULL OR NEW.days <= 0 THEN
        RAISE EXCEPTION 'จำนวนวันต้องมากกว่า 0';
      END IF;
      IF NEW.days > v_calendar_days THEN
        RAISE EXCEPTION 'จำนวนวัน (%) เกินช่วงวันที่ (% วัน)', NEW.days, v_calendar_days;
      END IF;
      -- กรณีลาวันเดียว: days ต้องเป็น 0.5 หรือ 1
      IF NEW.start_date = NEW.end_date AND NEW.days NOT IN (0.5, 1) THEN
        RAISE EXCEPTION 'ลาวันเดียวต้องเป็น 0.5 หรือ 1 เท่านั้น (ได้รับ %)', NEW.days;
      END IF;
    END;
    RETURN NEW;
  END IF;

  -- กรณีอื่น (เช่น approved → pending, rejected → pending) — block
  RAISE EXCEPTION 'ไม่มีสิทธิ์เปลี่ยน status จาก % เป็น %', OLD.status, NEW.status;
END $$;

DROP TRIGGER IF EXISTS trg_leave_request_anti_tamper ON public.leave_requests;
CREATE TRIGGER trg_leave_request_anti_tamper
  BEFORE UPDATE ON public.leave_requests
  FOR EACH ROW EXECUTE FUNCTION public.guard_leave_request_owner_tamper();

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Anti-tamper trigger สำหรับ leave_requests พร้อมใช้งาน';
  RAISE NOTICE '   - Owner: แก้ row ตัวเองได้เฉพาะตอน pending (ผ่านฟอร์ม)';
  RAISE NOTICE '            ยกเลิก: ทำได้ แต่ห้ามแก้ field อื่นพร้อมกัน';
  RAISE NOTICE '            ห้ามแตะ approved_by/at/note';
  RAISE NOTICE '            days ต้องสอดคล้องกับ start/end (defense-in-depth)';
  RAISE NOTICE '   - HR/admin/approver: bypass ทั้งหมด (override ได้ตามเดิม)';
END $$;

-- ═══════════════════════════════════════════════════════════
-- TEST CASES (login เป็น branch_staff แล้วลองใน console):
--
-- ❌ ควร block:
--   await DB.client.from('leave_requests').update({days: 30}).eq('id', '<my-pending>')
--   → "จำนวนวัน (30) เกินช่วงวันที่ (1 วัน)"
--
--   await DB.client.from('leave_requests').update({approved_by: '...'}).eq('id', '<my>')
--   → "ไม่มีสิทธิ์แก้ฟิลด์ของผู้อนุมัติ"
--
--   await DB.client.from('leave_requests').update({status:'approved'}).eq('id', '<my>')
--   → RLS block ที่ WITH CHECK ใน policy เดิม
--
-- ✅ ควรผ่าน:
--   ฟอร์ม submit ผ่าน DB.saveLeaveRequest({...}) — UI lock days/calc auto
--   ยกเลิก: update({status:'cancelled'}) → ผ่าน
-- ═══════════════════════════════════════════════════════════
