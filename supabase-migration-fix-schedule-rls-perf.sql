-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Fix RLS Performance on schedule_entries
--
-- ปัญหา: REST GET /schedule_entries → 500 (statement_timeout 57014)
-- รากเหตุ: policy "sched_entries_read" ทำ:
--   - OR EXISTS (JOIN 3 tables) ทุก row
--   - auth.uid() ถูกเรียกซ้ำหลายครั้ง
--   - subquery correlated กับ schedule_entries.schedule_week_id
--   → 74 rows × หลาย subquery → > 8 วินาที → timeout
--
-- แก้: รวม logic เป็น STABLE SECURITY DEFINER function
--   - คืน BOOLEAN ตรงๆ
--   - Postgres planner จะ cache ผลเพราะ STABLE
--   - 1 function call ต่อ row แทน 3+ subquery
--
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ════════ 1. helper: เช็คว่า user เห็น schedule_entry นี้ได้ไหม ════════
CREATE OR REPLACE FUNCTION public.can_view_schedule_entry(
  p_schedule_week_id UUID,
  p_employee_id      TEXT
)
RETURNS BOOLEAN
LANGUAGE PLPGSQL
SECURITY DEFINER
STABLE                       -- ★ STABLE = Postgres cache ผลใน query เดียวกัน
SET search_path = public
AS $$
DECLARE
  v_role            TEXT;
  v_my_emp_id       TEXT;
  v_my_branches     TEXT[];
  v_my_own_branch   TEXT;
  v_week_branch     TEXT;
BEGIN
  -- 1) ดึง profile ของ user ที่กำลัง login (ครั้งเดียวต่อ query เพราะ STABLE)
  SELECT up.role, up.employee_id, up.managed_branches, e.branch
    INTO v_role, v_my_emp_id, v_my_branches, v_my_own_branch
  FROM public.user_profiles up
  LEFT JOIN public.employees e ON e.id = up.employee_id
  WHERE up.user_id = auth.uid();

  IF v_role IS NULL THEN
    RETURN FALSE;
  END IF;

  -- 2) HR / admin / OM → เห็นทุก row
  IF v_role IN ('admin', 'hr', 'operation_manager') THEN
    RETURN TRUE;
  END IF;

  -- 3) Self — เห็น row ของตัวเองเสมอ (ดูตารางตัวเอง / ข้ามสาขา)
  IF v_my_emp_id IS NOT NULL AND v_my_emp_id = p_employee_id THEN
    RETURN TRUE;
  END IF;

  -- 4) BM / AM — เห็น row ที่ schedule_week อยู่ในสาขาที่ดูแล
  IF v_role IN ('branch_manager', 'area_manager') THEN
    SELECT branch_id INTO v_week_branch
    FROM public.schedule_weeks
    WHERE id = p_schedule_week_id;

    IF v_week_branch IS NULL THEN
      RETURN FALSE;
    END IF;

    -- ใช้ managed_branches ถ้ามี ไม่งั้น fallback ไป emp.branch
    IF v_my_branches IS NOT NULL AND array_length(v_my_branches, 1) > 0 THEN
      RETURN v_week_branch = ANY(v_my_branches);
    ELSIF v_my_own_branch IS NOT NULL THEN
      RETURN v_week_branch = v_my_own_branch;
    ELSE
      RETURN FALSE;
    END IF;
  END IF;

  RETURN FALSE;
END $$;

GRANT EXECUTE ON FUNCTION public.can_view_schedule_entry(UUID, TEXT) TO authenticated;

-- ════════ 2. helper: เช็คว่า user เขียน schedule_entry นี้ได้ไหม ════════
CREATE OR REPLACE FUNCTION public.can_write_schedule_entry(
  p_schedule_week_id UUID,
  p_employee_id      TEXT
)
RETURNS BOOLEAN
LANGUAGE PLPGSQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_role            TEXT;
  v_my_branches     TEXT[];
  v_my_own_branch   TEXT;
  v_week_branch     TEXT;
BEGIN
  SELECT up.role, up.managed_branches, e.branch
    INTO v_role, v_my_branches, v_my_own_branch
  FROM public.user_profiles up
  LEFT JOIN public.employees e ON e.id = up.employee_id
  WHERE up.user_id = auth.uid();

  IF v_role IS NULL THEN
    RETURN FALSE;
  END IF;

  -- HR / admin / OM → เขียนได้ทุก row
  IF v_role IN ('admin', 'hr', 'operation_manager') THEN
    RETURN TRUE;
  END IF;

  -- BM / AM เขียนได้เฉพาะสาขาที่ดูแล
  IF v_role IN ('branch_manager', 'area_manager') THEN
    SELECT branch_id INTO v_week_branch
    FROM public.schedule_weeks
    WHERE id = p_schedule_week_id;

    IF v_week_branch IS NULL THEN
      RETURN FALSE;
    END IF;

    IF v_my_branches IS NOT NULL AND array_length(v_my_branches, 1) > 0 THEN
      RETURN v_week_branch = ANY(v_my_branches);
    ELSIF v_my_own_branch IS NOT NULL THEN
      RETURN v_week_branch = v_my_own_branch;
    ELSE
      RETURN FALSE;
    END IF;
  END IF;

  RETURN FALSE;
END $$;

GRANT EXECUTE ON FUNCTION public.can_write_schedule_entry(UUID, TEXT) TO authenticated;

-- ════════ 3. Drop policies เก่า + create policies ใหม่ที่ใช้ function ════════
DROP POLICY IF EXISTS "sched_entries_read"  ON public.schedule_entries;
DROP POLICY IF EXISTS "sched_entries_write" ON public.schedule_entries;

CREATE POLICY "sched_entries_read" ON public.schedule_entries
  FOR SELECT TO authenticated
  USING (public.can_view_schedule_entry(schedule_week_id, employee_id));

CREATE POLICY "sched_entries_write" ON public.schedule_entries
  FOR ALL TO authenticated
  USING      (public.can_write_schedule_entry(schedule_week_id, employee_id))
  WITH CHECK (public.can_write_schedule_entry(schedule_week_id, employee_id));

-- ════════ 4. ทำ schedule_weeks policy ให้เร็วด้วย ════════
-- (เพราะ schedule page โหลด weeks ก่อน entries — ถ้า weeks ช้าก็เห็นปัญหาเหมือนกัน)
CREATE OR REPLACE FUNCTION public.can_view_schedule_week(p_branch_id TEXT)
RETURNS BOOLEAN
LANGUAGE PLPGSQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_role          TEXT;
  v_my_branches   TEXT[];
  v_my_own_branch TEXT;
BEGIN
  SELECT up.role, up.managed_branches, e.branch
    INTO v_role, v_my_branches, v_my_own_branch
  FROM public.user_profiles up
  LEFT JOIN public.employees e ON e.id = up.employee_id
  WHERE up.user_id = auth.uid();

  IF v_role IS NULL THEN
    RETURN FALSE;
  END IF;

  IF v_role IN ('admin', 'hr', 'operation_manager') THEN
    RETURN TRUE;
  END IF;

  IF v_role IN ('branch_manager', 'area_manager') THEN
    IF v_my_branches IS NOT NULL AND array_length(v_my_branches, 1) > 0 THEN
      RETURN p_branch_id = ANY(v_my_branches);
    ELSIF v_my_own_branch IS NOT NULL THEN
      RETURN p_branch_id = v_my_own_branch;
    ELSE
      RETURN FALSE;
    END IF;
  END IF;

  -- viewer / branch_staff — เห็น week ของสาขาตัวเอง (เพื่อดูตารางตัวเอง)
  RETURN v_my_own_branch IS NOT NULL AND p_branch_id = v_my_own_branch;
END $$;

GRANT EXECUTE ON FUNCTION public.can_view_schedule_week(TEXT) TO authenticated;

-- helper: เขียน schedule_week ได้ไหม (HR/admin/OM/BM/AM ที่ดูแลสาขา)
CREATE OR REPLACE FUNCTION public.can_write_schedule_week(p_branch_id TEXT)
RETURNS BOOLEAN
LANGUAGE PLPGSQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_role          TEXT;
  v_my_branches   TEXT[];
  v_my_own_branch TEXT;
BEGIN
  SELECT up.role, up.managed_branches, e.branch
    INTO v_role, v_my_branches, v_my_own_branch
  FROM public.user_profiles up
  LEFT JOIN public.employees e ON e.id = up.employee_id
  WHERE up.user_id = auth.uid();

  IF v_role IS NULL THEN RETURN FALSE; END IF;
  IF v_role IN ('admin', 'hr', 'operation_manager') THEN RETURN TRUE; END IF;

  IF v_role IN ('branch_manager', 'area_manager') THEN
    IF v_my_branches IS NOT NULL AND array_length(v_my_branches, 1) > 0 THEN
      RETURN p_branch_id = ANY(v_my_branches);
    ELSIF v_my_own_branch IS NOT NULL THEN
      RETURN p_branch_id = v_my_own_branch;
    END IF;
  END IF;

  RETURN FALSE;  -- viewer/branch_staff เขียนไม่ได้
END $$;

GRANT EXECUTE ON FUNCTION public.can_write_schedule_week(TEXT) TO authenticated;

DROP POLICY IF EXISTS "sched_weeks_read"  ON public.schedule_weeks;
DROP POLICY IF EXISTS "sched_weeks_write" ON public.schedule_weeks;

CREATE POLICY "sched_weeks_read" ON public.schedule_weeks
  FOR SELECT TO authenticated
  USING (public.can_view_schedule_week(branch_id));

CREATE POLICY "sched_weeks_write" ON public.schedule_weeks
  FOR ALL TO authenticated
  USING      (public.can_write_schedule_week(branch_id))
  WITH CHECK (public.can_write_schedule_week(branch_id));

-- ════════ 5. Reload PostgREST schema cache ════════
NOTIFY pgrst, 'reload schema';

-- ════════ 6. Verify ════════
DO $$
DECLARE v_count INT;
BEGIN
  SELECT count(*) INTO v_count
  FROM pg_policy
  WHERE polrelid = 'public.schedule_entries'::regclass;

  RAISE NOTICE '✅ schedule_entries มี % policies (คาดว่า 2)', v_count;

  SELECT count(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname IN ('can_view_schedule_entry','can_write_schedule_entry','can_view_schedule_week');

  RAISE NOTICE '✅ helper functions: % (คาดว่า 3)', v_count;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE 'ทดสอบที่หน้าเว็บ:';
  RAISE NOTICE '  1. Ctrl+Shift+R เพื่อล้าง cache';
  RAISE NOTICE '  2. เปิดหน้าตารางงาน — ควรโหลดเร็ว < 1 วินาที';
  RAISE NOTICE '  3. ถ้ายัง 500 → ดู Response body ใน Network tab';
  RAISE NOTICE '═══════════════════════════════════════════';
END $$;
