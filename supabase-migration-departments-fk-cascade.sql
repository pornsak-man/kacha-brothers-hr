-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: FK departments → ON UPDATE CASCADE
-- ให้รหัสฝ่าย (departments.id) แก้ไขได้ โดย Postgres จะ cascade ไปยัง
-- employees.department และ applicants.department อัตโนมัติ (atomic)
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ─── 1) EMPLOYEES.department ───
DO $$
DECLARE v_constraint TEXT;
BEGIN
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.employees'::regclass
    AND contype = 'f'
    AND confrelid = 'public.departments'::regclass;
  IF v_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.employees DROP CONSTRAINT %I', v_constraint);
    RAISE NOTICE 'Dropped old FK: %', v_constraint;
  END IF;
END $$;

ALTER TABLE public.employees
  ADD CONSTRAINT employees_department_fkey
  FOREIGN KEY (department) REFERENCES public.departments(id)
  ON DELETE SET NULL ON UPDATE CASCADE;

-- ─── 2) APPLICANTS.department ───
DO $$
DECLARE v_constraint TEXT;
BEGIN
  SELECT conname INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.applicants'::regclass
    AND contype = 'f'
    AND confrelid = 'public.departments'::regclass;
  IF v_constraint IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.applicants DROP CONSTRAINT %I', v_constraint);
    RAISE NOTICE 'Dropped old FK: %', v_constraint;
  END IF;
END $$;

ALTER TABLE public.applicants
  ADD CONSTRAINT applicants_department_fkey
  FOREIGN KEY (department) REFERENCES public.departments(id)
  ON DELETE SET NULL ON UPDATE CASCADE;

NOTIFY pgrst, 'reload schema';

-- ─── ตรวจสอบ ───
DO $$
DECLARE r RECORD;
BEGIN
  RAISE NOTICE '═══ FK constraints ที่อ้าง departments หลัง migration ═══';
  FOR r IN
    SELECT conname, conrelid::regclass AS table_name, confupdtype, confdeltype
    FROM pg_constraint
    WHERE contype = 'f' AND confrelid = 'public.departments'::regclass
  LOOP
    RAISE NOTICE '% [%]: ON UPDATE=% · ON DELETE=%',
      r.table_name, r.conname,
      CASE r.confupdtype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'r' THEN 'RESTRICT' WHEN 'a' THEN 'NO ACTION' ELSE r.confupdtype::text END,
      CASE r.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'r' THEN 'RESTRICT' WHEN 'a' THEN 'NO ACTION' ELSE r.confdeltype::text END;
  END LOOP;
  RAISE NOTICE '✅ ตอนนี้ UPDATE departments.id จะ cascade ไปยังพนักงาน + ผู้สมัครอัตโนมัติ';
END $$;
