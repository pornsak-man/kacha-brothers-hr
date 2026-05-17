-- ═══════════════════════════════════════════════════════════
-- KHACHA BROTHERS HR — Migration: Termination Date
-- เพิ่ม column วันพ้นสภาพการเป็นพนักงาน
-- รันใน Supabase SQL Editor ครั้งเดียว
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS termination_date DATE;
