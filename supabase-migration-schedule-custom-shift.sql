-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Custom Shift บนเซลล์ (สำหรับ PT)
-- เพิ่มคอลัมน์ในตาราง schedule_entries เพื่อให้กรอกเวลาเริ่ม-เลิกเอง
-- เฉพาะเซลล์นั้น (สำหรับ Part-time ที่ความยาวกะไม่ตายตัว 3-7 ชม.)
--
-- กฎ:
--   - ถ้า shift_id NOT NULL  → ใช้เวลาจากกะมาสเตอร์ (shifts.start_time / end_time)
--   - ถ้า shift_id IS NULL และมี custom_start_time → เป็นกะกำหนดเอง
--   - ถ้าทั้งคู่ NULL → placeholder row (เช่น คนข้ามสาขายังไม่ได้กำหนดกะ)
--
-- รันใน Supabase SQL Editor ครั้งเดียว — idempotent
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.schedule_entries
  ADD COLUMN IF NOT EXISTS custom_start_time    TIME,
  ADD COLUMN IF NOT EXISTS custom_end_time      TIME,
  ADD COLUMN IF NOT EXISTS custom_break_minutes INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS custom_label         TEXT;

-- ตรวจ consistency: ถ้ามี custom_start_time ต้องมี custom_end_time ด้วย
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.constraint_column_usage
    WHERE constraint_name = 'chk_schedule_custom_pair'
  ) THEN
    ALTER TABLE public.schedule_entries
      ADD CONSTRAINT chk_schedule_custom_pair
      CHECK (
        (custom_start_time IS NULL AND custom_end_time IS NULL)
        OR (custom_start_time IS NOT NULL AND custom_end_time IS NOT NULL)
      );
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
