-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Fix RLS Performance on employees
--
-- ปัญหา: employees query ช้า ~2.6 วินาที (433 rows)
-- รากเหตุ: policy ใช้ can_view_employee(id) ที่ถูกเรียก 433 ครั้ง
--   แม้เป็น STABLE — แต่ละครั้งทำ SELECT user_profiles ใหม่
--
-- แก้: ใช้ pattern (SELECT func()) เพื่อให้ Postgres ใช้ InitPlan
--   → ฟังก์ชันรันครั้งเดียวต่อ query แทน 433 ครั้ง
--   → คาดว่าจะเร็วขึ้น 10-50 เท่า
--
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ════════ 1. helper: คืน branch scope ของ user (cache ใน InitPlan) ════════
-- คืน TEXT[] ของ branches ที่ user เห็นได้
-- ถ้าเป็น HR/admin/OM → คืน NULL = "ทุกสาขา" (handle ใน policy)
CREATE OR REPLACE FUNCTION public.my_branch_scope()
RETURNS TEXT[]
LANGUAGE PLPGSQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_role          TEXT;
  v_branches      TEXT[];
  v_own_branch    TEXT;
BEGIN
  SELECT up.role, up.managed_branches, e.branch
    INTO v_role, v_branches, v_own_branch
  FROM public.user_profiles up
  LEFT JOIN public.employees e ON e.id = up.employee_id
  WHERE up.user_id = auth.uid();

  IF v_role IS NULL THEN
    RETURN ARRAY[]::TEXT[];  -- ไม่มี profile → empty (ดูได้แค่ตัวเอง)
  END IF;

  -- HR/admin/OM → NULL = ทุกสาขา
  IF v_role IN ('admin', 'hr', 'operation_manager') THEN
    RETURN NULL;
  END IF;

  -- BM/AM → managed_branches หรือ fallback ไป own_branch
  IF v_role IN ('branch_manager', 'area_manager') THEN
    IF v_branches IS NOT NULL AND array_length(v_branches, 1) > 0 THEN
      RETURN v_branches;
    ELSIF v_own_branch IS NOT NULL THEN
      RETURN ARRAY[v_own_branch];
    END IF;
  END IF;

  -- viewer / branch_staff — เห็นเฉพาะตัวเอง (handle ผ่าน my_employee_id)
  RETURN ARRAY[]::TEXT[];
END $$;

GRANT EXECUTE ON FUNCTION public.my_branch_scope() TO authenticated;

-- ════════ 2. helper: คืน employee_id ของ user เอง ════════
CREATE OR REPLACE FUNCTION public.my_employee_id()
RETURNS TEXT
LANGUAGE PLPGSQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE v_emp_id TEXT;
BEGIN
  SELECT employee_id INTO v_emp_id
  FROM public.user_profiles
  WHERE user_id = auth.uid();
  RETURN v_emp_id;
END $$;

GRANT EXECUTE ON FUNCTION public.my_employee_id() TO authenticated;

-- ════════ 3. Drop policy เก่า + create policy ใหม่ที่ใช้ InitPlan ════════
DROP POLICY IF EXISTS "employees_select_strict" ON public.employees;

CREATE POLICY "employees_select_strict" ON public.employees
  FOR SELECT TO authenticated
  USING (
    -- ★ Path 1: HR/admin/OM → my_branch_scope() คืน NULL → เห็นทุก row
    --   ใช้ EXISTS pattern เพื่อหลีกเลี่ยง type ambiguity
    EXISTS (SELECT 1 WHERE public.my_branch_scope() IS NULL)
    --
    -- ★ Path 2: BM/AM → branch ของ employee ต้องอยู่ใน scope
    --   ใช้ unnest แทน ANY — Postgres เข้าใจ type ชัด + รัน scope() ครั้งเดียวเพราะ STABLE
    OR branch IN (SELECT unnest(public.my_branch_scope()))
    --
    -- ★ Path 3: Self — เห็นตัวเองเสมอ
    OR id = (SELECT public.my_employee_id())
  );

-- ════════ 4. Optimize policies อื่นๆ บน employees (INSERT/UPDATE/DELETE) ถ้ามี ════════
-- ดูใน security-fix-c4 ว่ามี write policy อะไรอยู่
-- (ปกติ write จะใช้ผ่าน RPC ไม่ใช่ direct table → ไม่ critical)

-- ════════ 5. Reload PostgREST schema cache ════════
NOTIFY pgrst, 'reload schema';

-- ════════ 6. Verify ════════
DO $$
DECLARE
  v_count INT;
  v_scope TEXT[];
BEGIN
  SELECT count(*) INTO v_count
  FROM pg_policy
  WHERE polrelid = 'public.employees'::regclass
    AND polcmd = 'r';
  RAISE NOTICE '✅ employees SELECT policies: % (คาดว่า 1)', v_count;

  SELECT count(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname IN ('my_branch_scope','my_employee_id');
  RAISE NOTICE '✅ helper functions: % (คาดว่า 2)', v_count;

  -- ทดสอบเรียกฟังก์ชัน (เป็น postgres role — จะคืน empty array)
  v_scope := public.my_branch_scope();
  RAISE NOTICE 'my_branch_scope() ภายใต้ postgres role = % (คาดว่า empty)', v_scope;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE 'ทดสอบที่หน้าเว็บ:';
  RAISE NOTICE '  1. Ctrl+Shift+R ล้าง cache';
  RAISE NOTICE '  2. เปิดหน้า dashboard';
  RAISE NOTICE '  3. Console — slowest query: employees ควร < 500ms';
  RAISE NOTICE '  4. ทดสอบหน้าพนักงาน + ตารางงาน';
  RAISE NOTICE '═══════════════════════════════════════════';
END $$;
