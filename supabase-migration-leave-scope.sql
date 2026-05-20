-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Leave SELECT Scope
-- แก้ bug: Branch/Area Manager ไม่เห็นคำขอลาของลูกน้องในสาขา
--
-- เดิม: SELECT policy "read_own_or_admin" → admin/self เท่านั้น
-- ผล: branch_manager มีสิทธิ์อนุมัติแต่ "เห็น 0 rows" → กดอนุมัติไม่ได้
-- HR เห็นได้เพราะ "write_hr" policy เป็น FOR ALL (รวม SELECT)
--
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ลบ policy เก่า (รองรับทั้งชื่อเดิม + ใหม่ — รันซ้ำได้)
DROP POLICY IF EXISTS "read_own_or_admin" ON public.leave_requests;
DROP POLICY IF EXISTS "read_scoped"        ON public.leave_requests;

-- Policy ใหม่: ใครเห็น leave_requests row บ้าง
CREATE POLICY "read_scoped" ON public.leave_requests
  FOR SELECT TO authenticated
  USING (
    -- 1. admin + HR + operation_manager → เห็นทุกคำขอ
    public.is_hr_or_admin()
    OR public.current_user_role() = 'operation_manager'

    -- 2. ผู้อนุมัติของคำขอนี้ (จาก leave_approver_for) → เห็นได้
    --    ครอบคลุม branch_manager + area_manager ที่เป็นผู้อนุมัติจริง
    OR public.can_approve_leave_for(employee_id)

    -- 3. เจ้าของคำขอ → เห็นของตัวเอง
    OR employee_id = public.current_user_employee_id()

    -- 4. Manager: scope ตามสาขาที่ดูแล
    --    branch_manager → คำขอของพนักงานในสาขาตัวเอง
    --    area_manager  → คำขอของพนักงานใน managed_branches
    OR EXISTS (
      SELECT 1 FROM public.employees e
      WHERE e.id = leave_requests.employee_id
        AND (
          (public.current_user_role() = 'branch_manager'
            AND e.branch = public.current_user_branch())
          OR (public.current_user_role() = 'area_manager'
            AND e.branch = ANY(public.current_user_managed_branches()))
        )
    )
  );

NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════
-- ทดสอบหลังรัน migration:
--
-- 1. Login เป็น branch_manager ของสาขาหนึ่ง
-- 2. ไป "การลา" → tab "รออนุมัติ"
-- 3. ควรเห็นคำขอของพนักงานในสาขาตัวเอง พร้อมปุ่ม [อนุมัติ] [ปฏิเสธ]
--
-- ถ้ายังไม่เห็น — รัน query นี้ใน SQL Editor เพื่อ debug:
--   SELECT current_user_role(), current_user_branch(), current_user_employee_id();
--   → ดูว่า role + branch + employee_id ตรงกับที่คาดไหม
-- ═══════════════════════════════════════════════════════════
