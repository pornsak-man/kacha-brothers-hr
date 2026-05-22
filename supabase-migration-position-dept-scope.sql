-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: scope (ปฏิบัติ / สำนักงาน)
-- เพิ่มฟิลด์ scope ใน departments + position_levels
--   - 'operation' = ฝ่าย/ตำแหน่งของสายปฏิบัติการ (ครัว เสิร์ฟ ฯลฯ)
--   - 'office'    = ฝ่าย/ตำแหน่งของสายสำนักงาน (HR, บัญชี, ฯลฯ)
--   - NULL        = ไม่ระบุ (ใช้ได้ทุกฝ่าย — default)
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.departments
  ADD COLUMN IF NOT EXISTS scope TEXT;

ALTER TABLE public.position_levels
  ADD COLUMN IF NOT EXISTS scope TEXT;

-- constraint: ค่าได้แค่ operation / office / null
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'departments_scope_check') THEN
    ALTER TABLE public.departments
      ADD CONSTRAINT departments_scope_check
      CHECK (scope IS NULL OR scope IN ('operation', 'office'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'position_levels_scope_check') THEN
    ALTER TABLE public.position_levels
      ADD CONSTRAINT position_levels_scope_check
      CHECK (scope IS NULL OR scope IN ('operation', 'office'));
  END IF;
END $$;

-- index (ขนาดเล็ก — partial index เฉพาะที่มีค่า)
CREATE INDEX IF NOT EXISTS idx_dept_scope ON public.departments(scope) WHERE scope IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pos_scope  ON public.position_levels(scope) WHERE scope IS NOT NULL;

NOTIFY pgrst, 'reload schema';

DO $$
DECLARE
  v_dep_col BOOLEAN;
  v_pos_col BOOLEAN;
BEGIN
  SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'departments' AND column_name = 'scope') INTO v_dep_col;
  SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'position_levels' AND column_name = 'scope') INTO v_pos_col;
  IF v_dep_col AND v_pos_col THEN
    RAISE NOTICE '✅ เพิ่ม scope ครบทั้ง departments + position_levels';
    RAISE NOTICE '   ค่า default = NULL (ใช้ได้ทุกฝ่าย/ทั้ง 2 สาย)';
    RAISE NOTICE '   HR ตั้งค่าได้ผ่าน UI: ฝ่าย/ระดับตำแหน่ง';
  ELSE
    RAISE WARNING '⚠️ ตรวจสอบ migration';
  END IF;
END $$;
