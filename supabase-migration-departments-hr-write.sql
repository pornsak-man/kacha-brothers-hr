-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: ให้ HR เขียน departments ได้
-- เดิม: เฉพาะ admin เท่านั้นที่เพิ่ม/แก้/ลบฝ่ายได้
-- ใหม่: admin + HR (สอดคล้องกับเมนู UI ที่ใช้ requireHR())
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ─── DEPARTMENTS — เปลี่ยน write policy ───
DROP POLICY IF EXISTS "write_admin" ON public.departments;
DROP POLICY IF EXISTS "write_hr_admin" ON public.departments;

CREATE POLICY "write_hr_admin" ON public.departments
  FOR ALL TO authenticated
  USING (public.is_hr_or_admin())
  WITH CHECK (public.is_hr_or_admin());

NOTIFY pgrst, 'reload schema';

-- ─── ตรวจสอบ ───
DO $$
DECLARE v_policies INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_policies
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'departments';
  RAISE NOTICE '═══ Policies ของ departments หลัง migration ═══';
  RAISE NOTICE 'จำนวน policies: %', v_policies;
  RAISE NOTICE '✅ ตอนนี้ HR + admin เพิ่ม/แก้/ลบฝ่ายได้แล้ว';
  RAISE NOTICE '   พนักงานทั่วไป (branch_staff/viewer/manager) ยัง SELECT ได้อยู่ แต่เขียนไม่ได้';
END $$;
