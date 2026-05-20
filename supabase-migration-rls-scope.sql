-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: RLS Scope (Phase 2)
-- จำกัด SELECT ระดับ row ตาม role + branch + self
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
--
-- หลักการ:
--   • employees       : role-based row visibility (branch_staff/viewer = own branch
--                        for approver lookup, แต่ client mask salary/PII)
--   • financial tables (salary_history, loans, advances, allowances, evaluations)
--                     : stricter — branch_staff/viewer เห็นเฉพาะของตัวเอง
-- ═══════════════════════════════════════════════════════════

-- ─── HELPER FUNCTIONS ───

-- role ของ user ปัจจุบัน
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS TEXT
LANGUAGE SQL
SECURITY DEFINER
STABLE
AS $$
  SELECT role FROM public.user_profiles WHERE user_id = auth.uid()
$$;

-- employee_id ที่ผูกกับ user ปัจจุบัน
CREATE OR REPLACE FUNCTION public.current_user_employee_id()
RETURNS TEXT
LANGUAGE SQL
SECURITY DEFINER
STABLE
AS $$
  SELECT employee_id FROM public.user_profiles WHERE user_id = auth.uid()
$$;

-- managed_branches ของ user ปัจจุบัน (สำหรับ area_manager)
CREATE OR REPLACE FUNCTION public.current_user_managed_branches()
RETURNS TEXT[]
LANGUAGE SQL
SECURITY DEFINER
STABLE
AS $$
  SELECT COALESCE(managed_branches, '{}'::TEXT[])
  FROM public.user_profiles
  WHERE user_id = auth.uid()
$$;

-- branch ของ user ปัจจุบัน (derived จาก employee record)
CREATE OR REPLACE FUNCTION public.current_user_branch()
RETURNS TEXT
LANGUAGE SQL
SECURITY DEFINER
STABLE
AS $$
  SELECT e.branch
  FROM public.user_profiles p
  JOIN public.employees e ON e.id = p.employee_id
  WHERE p.user_id = auth.uid()
$$;

-- ตรวจว่า user มีสิทธิ์อ่าน row ของ employees (จาก id + branch)
-- ใช้สำหรับ policy บน employees table
CREATE OR REPLACE FUNCTION public.can_read_employee_row(emp_id TEXT, emp_branch TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
AS $$
  SELECT
    CASE public.current_user_role()
      WHEN 'admin'             THEN TRUE
      WHEN 'hr'                THEN TRUE
      WHEN 'operation_manager' THEN TRUE
      WHEN 'area_manager'      THEN emp_branch = ANY(public.current_user_managed_branches())
                                    OR emp_branch = public.current_user_branch()
      WHEN 'branch_manager'    THEN emp_branch = public.current_user_branch()
      WHEN 'branch_staff'      THEN emp_branch = public.current_user_branch()
      WHEN 'viewer'            THEN emp_id = public.current_user_employee_id()
      ELSE FALSE
    END
$$;

-- ตรวจว่า user มีสิทธิ์อ่าน row ที่อ้างอิงพนักงาน (financial tables)
-- เข้มกว่า can_read_employee_row — branch_staff/viewer เห็นเฉพาะของตัวเอง
CREATE OR REPLACE FUNCTION public.can_read_employee_financial(emp_id TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
AS $$
  SELECT
    CASE public.current_user_role()
      WHEN 'admin'             THEN TRUE
      WHEN 'hr'                THEN TRUE
      WHEN 'operation_manager' THEN TRUE
      WHEN 'area_manager'      THEN EXISTS (
                                      SELECT 1 FROM public.employees e
                                      WHERE e.id = emp_id
                                        AND (e.branch = ANY(public.current_user_managed_branches())
                                             OR e.branch = public.current_user_branch())
                                    )
      WHEN 'branch_manager'    THEN EXISTS (
                                      SELECT 1 FROM public.employees e
                                      WHERE e.id = emp_id
                                        AND e.branch = public.current_user_branch()
                                    )
      WHEN 'branch_staff'      THEN emp_id = public.current_user_employee_id()
      WHEN 'viewer'            THEN emp_id = public.current_user_employee_id()
      ELSE FALSE
    END
$$;

GRANT EXECUTE ON FUNCTION public.current_user_role()              TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_employee_id()       TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_managed_branches()  TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_branch()            TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_read_employee_row(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_read_employee_financial(TEXT) TO authenticated;

-- ─── REPLACE read_authenticated → SCOPED read policy ───

-- employees — ใช้ can_read_employee_row(id, branch)
DROP POLICY IF EXISTS "read_authenticated" ON public.employees;
DROP POLICY IF EXISTS "read_scoped"        ON public.employees;
CREATE POLICY "read_scoped" ON public.employees
  FOR SELECT TO authenticated
  USING (public.can_read_employee_row(id, branch));

-- salary_history — เข้มกว่า (financial)
DROP POLICY IF EXISTS "read_authenticated" ON public.salary_history;
DROP POLICY IF EXISTS "read_scoped"        ON public.salary_history;
CREATE POLICY "read_scoped" ON public.salary_history
  FOR SELECT TO authenticated
  USING (public.can_read_employee_financial(employee_id));

-- loans — เข้มกว่า (financial)
DROP POLICY IF EXISTS "read_authenticated" ON public.loans;
DROP POLICY IF EXISTS "read_scoped"        ON public.loans;
CREATE POLICY "read_scoped" ON public.loans
  FOR SELECT TO authenticated
  USING (public.can_read_employee_financial(employee_id));

-- advances — เข้มกว่า (financial)
DROP POLICY IF EXISTS "read_authenticated" ON public.advances;
DROP POLICY IF EXISTS "read_scoped"        ON public.advances;
CREATE POLICY "read_scoped" ON public.advances
  FOR SELECT TO authenticated
  USING (public.can_read_employee_financial(employee_id));

-- allowances — เข้มกว่า (financial)
DROP POLICY IF EXISTS "read_authenticated" ON public.allowances;
DROP POLICY IF EXISTS "read_scoped"        ON public.allowances;
CREATE POLICY "read_scoped" ON public.allowances
  FOR SELECT TO authenticated
  USING (public.can_read_employee_financial(employee_id));

-- evaluations — เข้มกว่า (financial / performance)
DROP POLICY IF EXISTS "read_authenticated" ON public.evaluations;
DROP POLICY IF EXISTS "read_scoped"        ON public.evaluations;
CREATE POLICY "read_scoped" ON public.evaluations
  FOR SELECT TO authenticated
  USING (public.can_read_employee_financial(employee_id));

NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════
-- หมายเหตุ:
-- • viewer = อ่านได้แค่ employee record ของตัวเอง (ดูประวัติตนเอง)
-- • branch_staff = อ่านเพื่อนร่วมสาขา (จำเป็นสำหรับหา leave approver)
--                  แต่ financial = เฉพาะของตัวเอง
-- • area_manager จะดู branch ที่กำหนดใน managed_branches + สาขาตัวเอง
-- • Client ยังต้อง mask salary/PII columns ตามที่ canSeeSalary() / isHR() check
--   เพราะ RLS ไม่ได้กรองระดับ column (จะต้องใช้ view + column privileges ในอนาคต)
-- ═══════════════════════════════════════════════════════════
