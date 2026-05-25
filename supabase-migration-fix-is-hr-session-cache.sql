-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — is_hr_or_admin per-request cache
--
-- ปัญหา: แม้ is_hr_or_admin() เป็น STABLE — Postgres ใน view context
--   ยังเรียกซ้ำต่อ row × column = ~46,000 ครั้งต่อ query
--   ทำให้ EXPLAIN ANALYZE แสดง 8 วินาทีสำหรับ 1000 rows
--
-- แก้: ใช้ session GUC (set_config local=true) cache ผลลัพธ์
--   - PostgREST แต่ละ HTTP request = 1 transaction
--   - cache ภายใน transaction = cache ภายใน 1 request
--   - guaranteed 1 call ต่อ request ไม่ขึ้นกับ planner
--
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ════════ 1. สร้าง wrapper ที่ cache ผ่าน session GUC ════════
CREATE OR REPLACE FUNCTION public.is_hr_or_admin_cached()
RETURNS BOOLEAN
LANGUAGE PLPGSQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cached TEXT;
  v_result BOOLEAN;
BEGIN
  -- 1) ดู cache ใน session GUC (transaction-local เพราะ is_local=true)
  v_cached := current_setting('khb.is_hr_cache', true);

  IF v_cached = 'true' THEN
    RETURN TRUE;
  ELSIF v_cached = 'false' THEN
    RETURN FALSE;
  END IF;

  -- 2) cache miss — คำนวณจริง + เก็บใน GUC
  -- ใช้ direct query แทน is_hr_or_admin() เดิม (ที่เรียก user_has_permission 2 ครั้ง)
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE user_id = auth.uid()
      AND role IN ('admin', 'hr')
  ) INTO v_result;

  -- 3) cache ใน GUC แบบ local (จบ transaction = clear)
  PERFORM set_config('khb.is_hr_cache', v_result::TEXT, true);

  RETURN v_result;
END $$;

GRANT EXECUTE ON FUNCTION public.is_hr_or_admin_cached() TO authenticated;

-- ════════ 2. สร้าง view ใหม่ใช้ฟังก์ชัน cached ════════
DO $$
DECLARE
  v_has_phone BOOLEAN;
  v_sql TEXT;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='employees' AND column_name='allowance_phone'
  ) INTO v_has_phone;

  DROP VIEW IF EXISTS public.employees_view;

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
    -- ★ ใช้ฟังก์ชัน cached + LATERAL บังคับ subquery ประเมินก่อน
    CROSS JOIN LATERAL (SELECT public.is_hr_or_admin_cached() AS is_hr) h;
  $V$;

  EXECUTE v_sql;
  RAISE NOTICE '✅ สร้าง view ใหม่ (allowance_phone: %)', CASE WHEN v_has_phone THEN 'มี' ELSE 'ไม่มี' END;
END $$;

GRANT SELECT ON public.employees_view TO authenticated;
NOTIFY pgrst, 'reload schema';

-- ════════ 3. Benchmark — เปรียบเทียบเวลาก่อน/หลัง ════════
DO $$
DECLARE
  v_start TIMESTAMP;
  v_ms NUMERIC;
  v_cnt INT;
BEGIN
  -- Reset cache ก่อน (ในกรณีเทสต์ใหม่)
  PERFORM set_config('khb.is_hr_cache', '', true);

  v_start := clock_timestamp();
  SELECT count(*) INTO v_cnt FROM (SELECT * FROM public.employees_view LIMIT 1000) t;
  v_ms := extract(milliseconds FROM clock_timestamp() - v_start);

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE '✅ employees_view + is_hr_or_admin_cached';
  RAISE NOTICE '   - cache key: khb.is_hr_cache (transaction-local)';
  RAISE NOTICE '   - guaranteed 1 call ต่อ HTTP request';
  RAISE NOTICE '   - SELECT * LIMIT 1000 ทดสอบ: % rows ใน % ms', v_cnt, ROUND(v_ms, 1);
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE 'ทดสอบที่หน้าเว็บ:';
  RAISE NOTICE '  1. Ctrl+Shift+R';
  RAISE NOTICE '  2. Console — slowest query ควรลดมาก';
END $$;
