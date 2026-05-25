-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Fix employees_view Performance
--
-- ปัญหา: GET /rest/v1/employees_view ใช้เวลา ~2.6 วินาที (433 rows)
-- รากเหตุ: view มี 23 columns × CASE WHEN is_hr_or_admin() THEN...
--   → Postgres เรียก is_hr_or_admin() = 23 × 433 ~= 10,000 ครั้ง!
--
-- แก้: CROSS JOIN scalar subquery → เรียก function ครั้งเดียวต่อ query
-- ═══════════════════════════════════════════════════════════

-- ตรวจสอบ allowance_phone column ก่อน (มีในบาง deployment)
DO $$
DECLARE
  v_has_phone BOOLEAN;
  v_sql TEXT;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='employees' AND column_name='allowance_phone'
  ) INTO v_has_phone;

  -- DROP view ก่อน — เพราะ CREATE OR REPLACE ห้าม drop/reorder columns
  DROP VIEW IF EXISTS public.employees_view;

  -- สร้าง view ใหม่ — CROSS JOIN scalar subquery สำหรับ is_hr_or_admin
  v_sql := $V$
    CREATE VIEW public.employees_view
    WITH (security_invoker = on)
    AS
    SELECT
      e.id, e.title, e.first_name, e.last_name, e.nickname, e.gender, e.dob,
      e.nationality, e.religion, e.education,
      e.phone, e.email, e.address, e.sub_district, e.district, e.province, e.postal_code,
      e.department, e.branch, e.position, e.position_title,
      e.employee_type, e.hire_date, e.termination_date,
      e.termination_reason, e.termination_note,
      e.status, e.photo_url, e.note,
      e.created_at, e.updated_at,
      CASE WHEN h.is_hr THEN e.national_id        ELSE NULL END AS national_id,
      CASE WHEN h.is_hr THEN e.passport_number    ELSE NULL END AS passport_number,
      CASE WHEN h.is_hr THEN e.work_permit_number ELSE NULL END AS work_permit_number,
      CASE WHEN h.is_hr THEN e.bank               ELSE NULL END AS bank,
      CASE WHEN h.is_hr THEN e.bank_account       ELSE NULL END AS bank_account,
      CASE WHEN h.is_hr THEN e.salary             ELSE NULL END AS salary,
      CASE WHEN h.is_hr THEN e.allowance_position ELSE NULL END AS allowance_position,
      CASE WHEN h.is_hr THEN e.allowance_travel   ELSE NULL END AS allowance_travel,
      CASE WHEN h.is_hr THEN e.allowance_food     ELSE NULL END AS allowance_food,
      CASE WHEN h.is_hr THEN e.allowance_per_diem ELSE NULL END AS allowance_per_diem,
      CASE WHEN h.is_hr THEN e.allowance_language ELSE NULL END AS allowance_language,
  $V$;

  IF v_has_phone THEN
    v_sql := v_sql || $V$
      CASE WHEN h.is_hr THEN e.allowance_phone    ELSE NULL END AS allowance_phone,
    $V$;
  END IF;

  v_sql := v_sql || $V$
      CASE WHEN h.is_hr THEN e.allowance_other    ELSE NULL END AS allowance_other,
      CASE WHEN h.is_hr THEN e.sso_no              ELSE NULL END AS sso_no,
      CASE WHEN h.is_hr THEN e.sso_enrolled_date   ELSE NULL END AS sso_enrolled_date,
      CASE WHEN h.is_hr THEN e.sso_terminated_date ELSE NULL END AS sso_terminated_date,
      CASE WHEN h.is_hr THEN e.sso_hospital        ELSE NULL END AS sso_hospital
    FROM public.employees e
    CROSS JOIN (SELECT public.is_hr_or_admin() AS is_hr) h;
  $V$;

  EXECUTE v_sql;

  RAISE NOTICE '✅ สร้าง view ใหม่ (allowance_phone: %)', CASE WHEN v_has_phone THEN 'มี' ELSE 'ไม่มี' END;
END $$;

GRANT SELECT ON public.employees_view TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════
-- ทดสอบเวลา
-- ═══════════════════════════════════════════════════════════
DO $$
DECLARE
  v_start TIMESTAMP;
  v_count INT;
  v_ms    NUMERIC;
BEGIN
  v_start := clock_timestamp();
  SELECT count(*) INTO v_count FROM public.employees_view;
  v_ms := extract(milliseconds from clock_timestamp() - v_start);

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE '✅ employees_view สร้างใหม่ — CROSS JOIN pattern';
  RAISE NOTICE '   - is_hr_or_admin() ถูกเรียก 1 ครั้ง (CROSS JOIN scalar)';
  RAISE NOTICE '   - ก่อน: ~23 × % = % ครั้ง', v_count, 23*v_count;
  RAISE NOTICE '   - SELECT count(*) ทดสอบ: % rows ใน % ms', v_count, ROUND(v_ms, 1);
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE 'ทดสอบที่หน้าเว็บ:';
  RAISE NOTICE '  1. Ctrl+Shift+R ล้าง cache';
  RAISE NOTICE '  2. เปิดหน้า dashboard';
  RAISE NOTICE '  3. Console — slowest query ควร < 500ms';
  RAISE NOTICE '═══════════════════════════════════════════';
END $$;
