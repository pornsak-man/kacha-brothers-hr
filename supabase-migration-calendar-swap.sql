-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Calendar Holiday Swap
-- เพิ่มการเปลี่ยนวันหยุดประเพณีเมื่อบริษัทได้รับยกเว้นทางกฎหมาย
-- เช่น พนักงานมาทำงานวันปีใหม่ แล้วเลื่อนไปหยุดวันอื่นแทน
--
-- 1) เพิ่มฟิลด์ swap_to_date / swap_note ใน calendar_items
-- 2) Attach audit_trigger เพื่อบันทึกประวัติทุกการเปลี่ยน
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.calendar_items
  ADD COLUMN IF NOT EXISTS swap_to_date DATE,     -- วันที่หยุดชดเชยแทน (ถ้าเป็นวันหยุดที่ถูกเลื่อน)
  ADD COLUMN IF NOT EXISTS swap_note    TEXT;     -- เหตุผล/หมายเหตุ เช่น "พนักงานมาทำงาน — ยกเว้นทางกฎหมาย"

CREATE INDEX IF NOT EXISTS idx_calendar_swap_to_date
  ON public.calendar_items(swap_to_date)
  WHERE swap_to_date IS NOT NULL;

COMMENT ON COLUMN public.calendar_items.swap_to_date IS
  'วันที่ใช้หยุดชดเชยแทนวันหยุดประเพณีนี้ (NULL = ไม่ได้เลื่อน)';
COMMENT ON COLUMN public.calendar_items.swap_note IS
  'เหตุผล/หมายเหตุการเปลี่ยนวันหยุด';

-- ─── Attach audit trigger (idempotent) ───
-- ทุกการเพิ่ม/แก้ไข/ลบ calendar_items จะถูกบันทึกใน audit_log อัตโนมัติ
-- รวมถึงการเปลี่ยน swap_to_date (old_data → new_data เห็นการเปลี่ยนแปลง)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'audit_trigger_fn') THEN
    DROP TRIGGER IF EXISTS audit_trigger ON public.calendar_items;
    CREATE TRIGGER audit_trigger
      AFTER INSERT OR UPDATE OR DELETE ON public.calendar_items
      FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_fn();
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
