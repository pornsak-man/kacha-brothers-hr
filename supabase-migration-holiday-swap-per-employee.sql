-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Holiday Swap (Per-Employee Scope)
-- ─────────────────────────────────────────────────────────
-- เปลี่ยน scope การเปลี่ยนวันหยุดประเพณีจาก "ทั้งบริษัท" → "ต่อพนักงาน"
--
-- ก่อนหน้า: trigger apply_holiday_swap อนุมัติคำขอแล้ว update
--           calendar_items.swap_to_date → กระทบทุกคน (ผิด!)
-- ใหม่:    calendar_items = วันหยุดประเพณีที่บริษัทกำหนด (เห็นเหมือนกันทุกคน)
--           holiday_swap_requests = สิทธิ์ขอหยุดแทนของแต่ละพนักงาน (per-employee)
--           UI คำนวณ swap state จาก holiday_swap_requests filtered ตาม employee_id
--
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- 1) ลบ trigger ที่ apply swap ลง calendar_items (เลิกใช้)
DROP TRIGGER IF EXISTS trg_apply_holiday_swap ON public.holiday_swap_requests;
DROP FUNCTION IF EXISTS public.apply_holiday_swap();

-- 2) เคลียร์ค่า swap_to_date/swap_note ที่ถูก trigger เก่า apply ลง calendar_items
--    (เพราะค่าเดิมเป็น company-wide ซึ่งเลิกใช้แล้ว — สิทธิ์ swap อยู่ที่แต่ละพนักงาน)
UPDATE public.calendar_items
   SET swap_to_date = NULL,
       swap_note    = NULL
 WHERE swap_to_date IS NOT NULL
    OR swap_note    IS NOT NULL;

-- 3) Drop คอลัมน์ swap_to_date / swap_note จาก calendar_items (เลิกใช้)
ALTER TABLE public.calendar_items
  DROP COLUMN IF EXISTS swap_to_date,
  DROP COLUMN IF EXISTS swap_note;

-- 4) ลบ index ที่ไม่จำเป็นแล้ว
DROP INDEX IF EXISTS public.idx_calendar_swap_to_date;

NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════
-- หมายเหตุ:
-- - คำขอเดิมใน holiday_swap_requests ยังอยู่ครบ (ไม่ได้ลบ)
--   แต่ผลกระทบของคำขอ approved ต่อ calendar_items ถูกย้อนกลับ
-- - ตอนนี้แต่ละพนักงานเห็น swap state ของตัวเองผ่าน UI เท่านั้น
-- - Approval workflow ยังเหมือนเดิม (chain เดียวกับการลา)
-- ═══════════════════════════════════════════════════════════
