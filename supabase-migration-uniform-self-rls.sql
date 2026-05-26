-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — RLS: Self-service Uniform Request
--
-- ปัญหา: write_admin policy เดิม → เฉพาะ admin insert ได้
--        พนักงาน (branch_staff/viewer/BM/AM) ที่ใช้ self-service ไม่ได้
--
-- แก้: เพิ่ม INSERT policy แยก:
--   - พนักงาน INSERT ได้ — เฉพาะ row ที่ employee_id = ตัวเอง
--   - status = 'pending' บังคับ (กันใส่ status อื่น)
--   - total_cost = 0 (กันใส่ราคาเอง)
--   - HR/admin ยังใช้ write_admin (ALL) สำหรับ UPDATE/DELETE
--
-- รันใน Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════

-- ════════ Self-INSERT policy (พนักงานยื่นคำขอตัวเอง) ════════
DROP POLICY IF EXISTS "uniform_req_self_insert" ON public.uniform_requests;
CREATE POLICY "uniform_req_self_insert" ON public.uniform_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    -- HR/admin bypass — สร้างแทนคนอื่นได้
    public.is_hr_or_admin()
    OR (
      -- พนักงาน: employee_id ต้องตรงกับ profile ของตัวเอง
      employee_id = (
        SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid()
      )
      -- status ต้องเป็น 'pending' (กันใส่ issued/approved เอง)
      AND status = 'pending'
      -- total_cost = 0 (HR จะใส่ราคาตอนจัดชุด)
      AND COALESCE(total_cost, 0) = 0
      -- ไม่มี applicant_id (self-service สำหรับพนักงานเท่านั้น)
      AND applicant_id IS NULL
    )
  );

-- ════════ Self-UPDATE policy (พนักงานยกเลิกคำขอตัวเองที่ยัง pending) ════════
DROP POLICY IF EXISTS "uniform_req_self_cancel" ON public.uniform_requests;
CREATE POLICY "uniform_req_self_cancel" ON public.uniform_requests
  FOR UPDATE TO authenticated
  USING (
    public.is_hr_or_admin()
    OR (
      employee_id = (
        SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid()
      )
      AND status = 'pending'   -- ยกเลิกได้เฉพาะ pending
    )
  )
  WITH CHECK (
    public.is_hr_or_admin()
    OR (
      employee_id = (
        SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid()
      )
      AND status IN ('pending', 'cancelled')  -- อนุญาตเปลี่ยนเป็น cancelled เท่านั้น
    )
  );

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Self-service uniform request policy ติดตั้งแล้ว';
  RAISE NOTICE '   - INSERT: พนักงานสร้างคำขอตัวเองได้ (status=pending, total_cost=0)';
  RAISE NOTICE '   - UPDATE: ยกเลิก/แก้คำขอตัวเองได้เฉพาะตอน pending';
  RAISE NOTICE '   - HR/admin ยังใช้ write_admin (ALL) ได้ปกติ';
END $$;
