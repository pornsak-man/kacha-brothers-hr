-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — เพิ่ม allowance_phone (สวัสดิการค่าโทรศัพท์)
-- ═══════════════════════════════════════════════════════════
-- เพิ่มคอลัมน์ใน employees + salary_history (เก็บประวัติการปรับ)
-- + recreate view employees_view ให้รวม allowance_phone (mask สำหรับ non-HR)
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ─── 1. เพิ่มคอลัมน์ใน employees ───
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS allowance_phone NUMERIC(12,2) DEFAULT 0;

COMMENT ON COLUMN public.employees.allowance_phone IS 'สวัสดิการค่าโทรศัพท์ (บาท/เดือน)';

-- ─── 2. เพิ่มคอลัมน์ใน salary_history (old/new ตามรูปแบบของ allowance_* อื่น) ───
ALTER TABLE public.salary_history
  ADD COLUMN IF NOT EXISTS old_allowance_phone NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS new_allowance_phone NUMERIC(12,2);

-- ─── 3. Recreate employees_view ให้รวม allowance_phone (mask non-HR) ───
-- ต้อง DROP + CREATE เพราะ CREATE OR REPLACE VIEW ไม่ยอมเพิ่ม column ที่ไม่ตรงโครงเดิม
DROP VIEW IF EXISTS public.employees_view;

CREATE VIEW public.employees_view
WITH (security_invoker = on)
AS
SELECT
  -- ─── ข้อมูลทั่วไป ───
  id, title, first_name, last_name, nickname, gender, dob,
  nationality, religion, education,
  phone, email, address, sub_district, district, province, postal_code,
  department, branch, position, position_title,
  employee_type, hire_date, termination_date,
  termination_reason, termination_note,
  status, photo_url, note,
  created_at, updated_at,

  -- ─── PII ───
  CASE WHEN public.is_hr_or_admin() THEN national_id        ELSE NULL END AS national_id,
  CASE WHEN public.is_hr_or_admin() THEN passport_number    ELSE NULL END AS passport_number,
  CASE WHEN public.is_hr_or_admin() THEN work_permit_number ELSE NULL END AS work_permit_number,
  CASE WHEN public.is_hr_or_admin() THEN bank               ELSE NULL END AS bank,
  CASE WHEN public.is_hr_or_admin() THEN bank_account       ELSE NULL END AS bank_account,

  -- ─── ค่าจ้าง + สวัสดิการ ───
  CASE WHEN public.is_hr_or_admin() THEN salary             ELSE NULL END AS salary,
  CASE WHEN public.is_hr_or_admin() THEN allowance_position ELSE NULL END AS allowance_position,
  CASE WHEN public.is_hr_or_admin() THEN allowance_travel   ELSE NULL END AS allowance_travel,
  CASE WHEN public.is_hr_or_admin() THEN allowance_food     ELSE NULL END AS allowance_food,
  CASE WHEN public.is_hr_or_admin() THEN allowance_per_diem ELSE NULL END AS allowance_per_diem,
  CASE WHEN public.is_hr_or_admin() THEN allowance_language ELSE NULL END AS allowance_language,
  CASE WHEN public.is_hr_or_admin() THEN allowance_phone    ELSE NULL END AS allowance_phone,  -- 🆕
  CASE WHEN public.is_hr_or_admin() THEN allowance_other    ELSE NULL END AS allowance_other,

  -- ─── ประกันสังคม ───
  CASE WHEN public.is_hr_or_admin() THEN sso_no              ELSE NULL END AS sso_no,
  CASE WHEN public.is_hr_or_admin() THEN sso_enrolled_date   ELSE NULL END AS sso_enrolled_date,
  CASE WHEN public.is_hr_or_admin() THEN sso_terminated_date ELSE NULL END AS sso_terminated_date,
  CASE WHEN public.is_hr_or_admin() THEN sso_hospital        ELSE NULL END AS sso_hospital
FROM public.employees;

GRANT SELECT ON public.employees_view TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ เพิ่ม allowance_phone ใน employees + salary_history + employees_view แล้ว';
  RAISE NOTICE '   - employees.allowance_phone (DEFAULT 0)';
  RAISE NOTICE '   - salary_history.old_allowance_phone / new_allowance_phone';
  RAISE NOTICE '   - employees_view รวม mask CASE WHEN is_hr_or_admin();';
  RAISE NOTICE '   ขั้นถัดไป: deploy JS ที่ map allowancePhone ทุกจุด (form, import, export, salary report)';
END $$;
