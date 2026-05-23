-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Security fix M1: Mask sensitive employee columns
-- ปัญหา: RLS scope ของ employees ให้ branch_manager/staff อ่าน row ลูกน้องได้ —
--        รวมคอลัมน์อ่อนไหว salary, bank_account, national_id, passport_number,
--        allowance_*, sso_*  → PDPA violation
-- แก้:   สร้าง view "employees_view" ที่ใช้ CASE mask sensitive fields
--        ตาม is_hr_or_admin() — HR เห็นข้อมูลครบ, non-HR เห็น NULL
-- การใช้: JS แอปต้อง query 'employees_view' แทน 'employees' (commit คู่กัน)
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
--
-- Phase 2 ที่เหลือ (อนาคต): REVOKE SELECT ON employees FROM authenticated
--   เพื่อกัน console bypass — ต้อง refactor realtime subscription ก่อน
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.employees_view
WITH (security_invoker = on)  -- RLS ของตาราง employees ยังคงใช้ผ่าน view
AS
SELECT
  -- ─── ข้อมูลทั่วไป (เปิดให้ดูได้) ───
  id, title, first_name, last_name, nickname, gender, dob,
  nationality, religion, education,
  phone, email, address, sub_district, district, province, postal_code,
  department, branch, position, position_title,
  employee_type, hire_date, termination_date,
  termination_reason, termination_note,
  status, photo_url, note,
  created_at, updated_at,

  -- ─── PII ที่อ่อนไหว — เปิดเผยเฉพาะ HR/admin ───
  CASE WHEN public.is_hr_or_admin() THEN national_id     ELSE NULL END AS national_id,
  CASE WHEN public.is_hr_or_admin() THEN passport_number ELSE NULL END AS passport_number,
  CASE WHEN public.is_hr_or_admin() THEN work_permit_number ELSE NULL END AS work_permit_number,
  CASE WHEN public.is_hr_or_admin() THEN bank           ELSE NULL END AS bank,
  CASE WHEN public.is_hr_or_admin() THEN bank_account   ELSE NULL END AS bank_account,

  -- ─── ค่าจ้าง — เปิดเผยเฉพาะ HR/admin ───
  CASE WHEN public.is_hr_or_admin() THEN salary             ELSE NULL END AS salary,
  CASE WHEN public.is_hr_or_admin() THEN allowance_position ELSE NULL END AS allowance_position,
  CASE WHEN public.is_hr_or_admin() THEN allowance_travel   ELSE NULL END AS allowance_travel,
  CASE WHEN public.is_hr_or_admin() THEN allowance_food     ELSE NULL END AS allowance_food,
  CASE WHEN public.is_hr_or_admin() THEN allowance_per_diem ELSE NULL END AS allowance_per_diem,
  CASE WHEN public.is_hr_or_admin() THEN allowance_language ELSE NULL END AS allowance_language,
  CASE WHEN public.is_hr_or_admin() THEN allowance_other    ELSE NULL END AS allowance_other,

  -- ─── ประกันสังคม — HR/admin เท่านั้น ───
  CASE WHEN public.is_hr_or_admin() THEN sso_no              ELSE NULL END AS sso_no,
  CASE WHEN public.is_hr_or_admin() THEN sso_enrolled_date   ELSE NULL END AS sso_enrolled_date,
  CASE WHEN public.is_hr_or_admin() THEN sso_terminated_date ELSE NULL END AS sso_terminated_date,
  CASE WHEN public.is_hr_or_admin() THEN sso_hospital        ELSE NULL END AS sso_hospital
FROM public.employees;

GRANT SELECT ON public.employees_view TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ employees_view สร้างแล้ว — masking sensitive cols ผ่าน CASE + is_hr_or_admin()';
  RAISE NOTICE '   HR/admin    → เห็น salary, ปชช, bank, allowance, sso ครบ';
  RAISE NOTICE '   non-HR/staff → คอลัมน์เหล่านี้คืน NULL';
  RAISE NOTICE '   JS แอปต้องเปลี่ยน .from(''employees'') → .from(''employees_view'') สำหรับ SELECT';
  RAISE NOTICE '   (commit JS แยก) — writes ยัง .from(''employees'') ตามเดิม';
END $$;

-- ═══════════════════════════════════════════════════════════
-- ทดสอบหลังรัน:
--   1) HR login → console:
--      DB.client.from('employees_view').select('id, salary, national_id').limit(1)
--      → salary + national_id มีค่าจริง
--   2) branch_staff login → console:
--      DB.client.from('employees_view').select('id, salary, national_id').limit(1)
--      → salary = null, national_id = null (masked)
--   3) Direct table (ตอนนี้ยังเปิดอยู่ — Phase 2 จะปิด):
--      DB.client.from('employees').select('salary, national_id').limit(1)
--      → ยังเห็นค่าจริง (residual risk รอ Phase 2)
-- ═══════════════════════════════════════════════════════════
