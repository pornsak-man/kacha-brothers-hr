-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Termination reason + note
-- เพิ่มฟิลด์ "เหตุผลการพ้นสภาพ" + "รายละเอียดเพิ่มเติม"
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS termination_reason TEXT,
  ADD COLUMN IF NOT EXISTS termination_note   TEXT;

-- รีเฟรช schema cache ของ Supabase REST API
NOTIFY pgrst, 'reload schema';

-- ─── เหตุผลที่ใช้บ่อย (UI dropdown) ───
--   ลาออก
--   ครบสัญญาจ้าง
--   ถูกเลิกจ้าง
--   ไล่ออก (ผิดวินัย)
--   เกษียณอายุ
--   เสียชีวิต
--   อื่นๆ (พิมพ์เอง)
-- ═══════════════════════════════════════════════════════════
