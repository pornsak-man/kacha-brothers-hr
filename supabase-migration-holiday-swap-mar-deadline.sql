-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Business Rule: วันหยุดชดเชยข้ามปี
--
-- กฎ:
--   - วันหยุดประเพณีเดือน ม.ค.-พ.ย. → ชดเชยภายในปีเดียวกัน (≤ 31 ธ.ค.)
--   - วันหยุดประเพณีเดือน ธ.ค.    → ชดเชยภายใน 31 มี.ค. ปีถัดไป
--
-- Defense-in-depth: validation มีทั้ง frontend (app.js) + DB constraint
-- ป้องกัน:
--   - direct SQL/REST bypass frontend
--   - HR override โดยไม่ตั้งใจ (ระบบเตือน + reject)
--
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ════════ 1. Trigger function — เช็คก่อน INSERT/UPDATE ════════
CREATE OR REPLACE FUNCTION public.enforce_holiday_swap_deadline()
RETURNS TRIGGER
LANGUAGE PLPGSQL
SET search_path = public
AS $$
DECLARE
  v_holiday_date DATE;
  v_max_swap_date DATE;
  v_holiday_month INT;
BEGIN
  -- ดึงวันที่ของ calendar_item ที่อ้างถึง
  SELECT date INTO v_holiday_date
  FROM public.calendar_items
  WHERE id = NEW.calendar_item_id;

  IF v_holiday_date IS NULL THEN
    RAISE EXCEPTION 'ไม่พบวันหยุดประเพณี (calendar_item_id=%)', NEW.calendar_item_id
      USING ERRCODE = '23503';
  END IF;

  v_holiday_month := EXTRACT(MONTH FROM v_holiday_date)::INT;

  -- คำนวณ deadline
  IF v_holiday_month = 12 THEN
    -- ธันวาคม → 31 มีนาคม ปีถัดไป
    v_max_swap_date := (DATE_TRUNC('year', v_holiday_date) + INTERVAL '1 year 2 months 30 days')::DATE;
    -- = วันที่ 31 มี.ค. ปีถัดไป
  ELSE
    -- เดือนอื่น → 31 ธ.ค. ของปีเดียวกัน
    v_max_swap_date := (DATE_TRUNC('year', v_holiday_date) + INTERVAL '1 year - 1 day')::DATE;
  END IF;

  -- เช็ค swap_to_date ≤ max_swap_date
  IF NEW.swap_to_date > v_max_swap_date THEN
    RAISE EXCEPTION 'วันหยุดชดเชย % เกินกรอบ % (วันหยุดประเพณี % — เดือน %)',
      NEW.swap_to_date, v_max_swap_date, v_holiday_date, v_holiday_month
      USING ERRCODE = '22023',
            HINT = CASE
              WHEN v_holiday_month = 12
                THEN 'วันหยุดเดือนธันวาคม ชดเชยได้ภายใน 31 มี.ค. ปีถัดไป'
              ELSE 'วันหยุดเดือน ม.ค.-พ.ย. ชดเชยได้ภายในปีเดียวกัน (≤ 31 ธ.ค.)'
            END;
  END IF;

  -- เช็ค swap_to_date > holiday_date (ต้องเป็นวันหลังวันหยุด)
  IF NEW.swap_to_date <= v_holiday_date THEN
    RAISE EXCEPTION 'วันหยุดชดเชย % ต้องเป็นวันหลังวันหยุดประเพณี %',
      NEW.swap_to_date, v_holiday_date
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END $$;

-- ════════ 2. Drop trigger เก่า (ถ้ามี) + create ใหม่ ════════
DROP TRIGGER IF EXISTS trg_enforce_holiday_swap_deadline ON public.holiday_swap_requests;
CREATE TRIGGER trg_enforce_holiday_swap_deadline
  BEFORE INSERT OR UPDATE OF swap_to_date, calendar_item_id
  ON public.holiday_swap_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_holiday_swap_deadline();

NOTIFY pgrst, 'reload schema';

-- ════════ 3. Verify ════════
DO $$
DECLARE
  v_test_dec  DATE := '2026-12-05';
  v_test_nov  DATE := '2026-11-15';
  v_max_dec   DATE;
  v_max_nov   DATE;
BEGIN
  v_max_dec := (DATE_TRUNC('year', v_test_dec) + INTERVAL '1 year 2 months 30 days')::DATE;
  v_max_nov := (DATE_TRUNC('year', v_test_nov) + INTERVAL '1 year - 1 day')::DATE;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE '✅ Trigger ติดตั้งเสร็จ — กฎวันหยุดชดเชย:';
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE '  วันหยุด %  (ธ.ค.)  → ชดเชยถึง %  ✓', v_test_dec, v_max_dec;
  RAISE NOTICE '  วันหยุด %  (พ.ย.)  → ชดเชยถึง %  ✓', v_test_nov, v_max_nov;
  RAISE NOTICE '';
  RAISE NOTICE '  ถ้า swap_to_date เกิน → trigger จะ throw error';
  RAISE NOTICE '  Error code 22023 (invalid_parameter_value)';
  RAISE NOTICE '  HINT message อธิบายกฎ — frontend จะแสดงให้ user';
END $$;
