-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — RLS expansion สำหรับ chain workflow
--
-- ปัญหา: can_approve_leave_for() เดิมตรวจเฉพาะ "top position holder"
--        ของสาขา → AM/OM ที่ดูแลสาขาผ่าน user_profiles.managed_branches
--        ไม่ผ่าน RLS UPDATE → "Cannot coerce the result to a single JSON object"
--
-- แก้: ขยาย can_approve_leave_for() ให้รวม chain roles
--      (branch_manager / area_manager / operation_manager) ที่ดูแลสาขา
--      ของพนักงานนั้น — ใช้ทั้งเป็น approver ของระบบเดิมและ chain
--
-- รันใน Supabase SQL Editor ครั้งเดียว — idempotent (CREATE OR REPLACE)
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.can_approve_leave_for(p_employee_id TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    -- 1. เดิม: ผู้อนุมัติตาม position level สูงสุดของสาขา (branch head)
    EXISTS (
      SELECT 1
      FROM public.user_profiles up
      WHERE up.user_id = auth.uid()
        AND up.employee_id IS NOT NULL
        AND up.employee_id = public.leave_approver_for(p_employee_id)
    )
    -- 2. ใหม่: chain role (BM/AM/OM) ที่ดูแลสาขาของพนักงานนี้
    --    ใช้ทั้ง RLS update และ trigger bypass
    OR EXISTS (
      SELECT 1
      FROM public.user_profiles up
      JOIN public.employees emp ON emp.id = p_employee_id
      WHERE up.user_id = auth.uid()
        AND up.role IN ('branch_manager', 'area_manager', 'operation_manager')
        AND (
          -- managed_branches override → ใช้ตามนั้น
          (up.managed_branches IS NOT NULL
           AND array_length(up.managed_branches, 1) > 0
           AND emp.branch = ANY(up.managed_branches))
          -- ไม่งั้น fallback ใช้ branch ของ user เอง
          OR emp.branch = (
            SELECT e2.branch
            FROM public.employees e2
            JOIN public.user_profiles up2 ON up2.employee_id = e2.id
            WHERE up2.user_id = auth.uid()
            LIMIT 1
          )
        )
    )
$$;

GRANT EXECUTE ON FUNCTION public.can_approve_leave_for(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ can_approve_leave_for() ขยายแล้ว — ครอบ chain roles';
  RAISE NOTICE '   AM / OM / BM ที่ดูแลสาขาของพนักงาน → UPDATE leave_requests ได้';
  RAISE NOTICE '   Anti-tamper trigger ก็จะ bypass ให้ chain roles ด้วย (ใช้ฟังก์ชันเดียวกัน)';
END $$;
