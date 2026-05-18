-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: RBAC Hierarchy
-- ขยาย role ของ user_profiles จาก 2 → 7 ระดับ
-- เพิ่ม managed_branches สำหรับ Area Manager (ดูแลหลายสาขา)
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ── A. ขยาย role CHECK constraint ──
-- ลำดับ role: admin > hr > operation_manager > area_manager > branch_manager > branch_staff > viewer
ALTER TABLE public.user_profiles DROP CONSTRAINT IF EXISTS user_profiles_role_check;
ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_role_check
  CHECK (role IN ('admin', 'hr', 'operation_manager', 'area_manager', 'branch_manager', 'branch_staff', 'viewer'));

-- ── B. เพิ่ม managed_branches (TEXT[]) สำหรับ Area Manager / Operation Manager ──
-- HR / OM = ใช้ array ว่าง (= ทุกสาขา); AM = ระบุสาขาที่รับผิดชอบ; BM/BS = derived from employee.branch
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS managed_branches TEXT[] DEFAULT '{}'::TEXT[];

-- ── C. แก้ set_employee_role() ให้รับ role ใหม่ + รองรับ managed_branches ──
DROP FUNCTION IF EXISTS public.set_employee_role(TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.set_employee_role(
  p_employee_id TEXT,
  p_role        TEXT,
  p_branches    TEXT[] DEFAULT NULL
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ต้องเป็น admin เท่านั้น';
  END IF;
  IF p_role NOT IN ('admin', 'hr', 'operation_manager', 'area_manager', 'branch_manager', 'branch_staff', 'viewer') THEN
    RAISE EXCEPTION 'role ไม่ถูกต้อง: %', p_role;
  END IF;

  UPDATE public.user_profiles
  SET role             = p_role,
      managed_branches = COALESCE(p_branches, managed_branches)
  WHERE employee_id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบบัญชีของพนักงาน %', p_employee_id;
  END IF;

  RETURN jsonb_build_object('employee_id', p_employee_id, 'role', p_role, 'managed_branches', p_branches);
END $$;

GRANT EXECUTE ON FUNCTION public.set_employee_role(TEXT, TEXT, TEXT[]) TO authenticated;

-- ── D. is_admin() คงเดิม (true เฉพาะ role='admin') ──
-- เพิ่ม helper: is_hr_or_admin() — ใช้ใน RLS policy ที่ HR เข้าถึงได้เท่ากับ admin
CREATE OR REPLACE FUNCTION public.is_hr_or_admin()
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE user_id = auth.uid() AND role IN ('admin', 'hr')
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_hr_or_admin() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ─── หมายเหตุ ───
-- • Auto-detect role ทำที่ client (JavaScript) ไม่ใช่ DB — เพื่อความยืดหยุ่น
-- • RLS policy ปัจจุบัน (admin write, authenticated read) ยังใช้ได้
-- • ถ้าจะเพิ่ม scope filter ที่ DB level → ปรับ RLS policies ทีหลัง (Phase 2/3)
-- • Phase 1 นี้ เน้น schema + RPC พอ — logic scope ทำที่ client ก่อน
-- ═══════════════════════════════════════════════════════════
