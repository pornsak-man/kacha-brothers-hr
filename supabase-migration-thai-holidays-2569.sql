-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — แก้วันหยุดประเพณีไทยปี 2569 ตามประกาศ ครม.
--
-- แก้ตามภาพ list จาก ครม. ปี 2569 — 14 รายการ
--   (ไม่รวมวันรัฐธรรมนูญ 10 ธ.ค. ตามภาพ)
--
-- กลยุทธ์ UPSERT — ไม่ลบ row เดิม (กัน CASCADE ลบ holiday_swap_requests)
--   1. UPDATE title ของ row ที่ date ตรง — keep id เดิม
--   2. INSERT รายการใหม่ที่ยังไม่มีใน DB
--
-- ผลข้าง: ถ้าระบบมี 10 ธ.ค. รัฐธรรมนูญ — จะ "เกิน" จากภาพ 1 รายการ
--   → ลบผ่าน UI ปุ่ม "ลบ" หรือ uncomment DELETE block ท้ายไฟล์
-- ═══════════════════════════════════════════════════════════

-- ════════ UPSERT 14 รายการตามภาพ ════════
WITH new_data (date, title, type) AS (
  VALUES
    ('2026-01-01'::DATE, 'วันขึ้นปีใหม่', 'holiday'),
    ('2026-03-03'::DATE, 'วันมาฆบูชา', 'holiday'),
    ('2026-04-06'::DATE, 'วันพระบาทสมเด็จพระพุทธยอดฟ้าจุฬาโลกมหาราช และวันที่ระลึกมหาจักรีบรมราชวงศ์', 'holiday'),
    ('2026-04-13'::DATE, 'วันสงกรานต์', 'holiday'),
    ('2026-04-14'::DATE, 'วันสงกรานต์', 'holiday'),
    ('2026-04-15'::DATE, 'วันสงกรานต์', 'holiday'),
    ('2026-05-01'::DATE, 'วันแรงงานแห่งชาติ', 'holiday'),
    ('2026-06-03'::DATE, 'วันเฉลิมพระชนมพรรษาสมเด็จพระนางเจ้าสุทิดา พัชรสุธาพิมลลักษณ พระบรมราชินี', 'holiday'),
    ('2026-07-28'::DATE, 'วันเฉลิมพระชนมพรรษา พระบาทสมเด็จพระเจ้าอยู่หัว', 'holiday'),
    ('2026-08-12'::DATE, 'วันคล้ายวันพระราชสมภพ สมเด็จพระนางเจ้าสิริกิติ์ พระบรมราชินีนาถ พระบรมราชชนนีพันปีหลวง และวันแม่แห่งชาติ', 'holiday'),
    ('2026-10-13'::DATE, 'วันนวมินทรมหาราช', 'holiday'),
    ('2026-10-23'::DATE, 'วันปิยมหาราช', 'holiday'),
    ('2026-12-05'::DATE, 'วันคล้ายวันพระบรมราชสมภพ พระบาทสมเด็จพระบรมชนกาธิเบศร มหาภูมิพลอดุลยเดชมหาราช บรมนาถบพิตร วันชาติ และวันพ่อแห่งชาติ', 'holiday'),
    ('2026-12-31'::DATE, 'วันสิ้นปี', 'holiday')
),
-- 1) UPDATE row ที่ date ตรง — keep id (กัน CASCADE swap_requests)
update_existing AS (
  UPDATE public.calendar_items c
  SET title = nd.title, type = nd.type
  FROM new_data nd
  WHERE c.date = nd.date AND c.type = 'holiday'
  RETURNING c.date
)
-- 2) INSERT รายการที่ยังไม่มี
INSERT INTO public.calendar_items (date, title, type)
SELECT date, title, type FROM new_data
WHERE date NOT IN (SELECT date FROM update_existing);

-- ════════ Verify + แจ้งเตือนรายการที่ "เกิน" ภาพ ════════
DO $$
DECLARE
  v_row     RECORD;
  v_extra   RECORD;
  v_target  TEXT[] := ARRAY[
    '2026-01-01','2026-03-03','2026-04-06','2026-04-13','2026-04-14','2026-04-15',
    '2026-05-01','2026-06-03','2026-07-28','2026-08-12','2026-10-13','2026-10-23',
    '2026-12-05','2026-12-31'
  ];
  v_count INT;
BEGIN
  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE '✅ วันหยุดประเพณีปี 2569 หลังแก้:';
  RAISE NOTICE '═══════════════════════════════════════════';

  v_count := 0;
  FOR v_row IN
    SELECT date, title FROM public.calendar_items
    WHERE date >= '2026-01-01' AND date <= '2026-12-31'
      AND type = 'holiday'
    ORDER BY date
  LOOP
    v_count := v_count + 1;
    RAISE NOTICE '  %. % — %', v_count, to_char(v_row.date, 'DD/MM/YYYY'), v_row.title;
  END LOOP;
  RAISE NOTICE '';
  RAISE NOTICE 'รวม % รายการ', v_count;

  -- เช็ครายการที่ไม่อยู่ในภาพ ครม. (เช่น 10 ธ.ค. รัฐธรรมนูญ)
  RAISE NOTICE '';
  RAISE NOTICE '─── รายการที่ "เกิน" จากภาพ ครม. (อาจต้องลบผ่าน UI) ───';
  v_count := 0;
  FOR v_extra IN
    SELECT date, title FROM public.calendar_items
    WHERE date >= '2026-01-01' AND date <= '2026-12-31'
      AND type = 'holiday'
      AND NOT (date::TEXT = ANY(v_target))
    ORDER BY date
  LOOP
    v_count := v_count + 1;
    RAISE NOTICE '  ⚠ % — %', to_char(v_extra.date, 'DD/MM/YYYY'), v_extra.title;
  END LOOP;
  IF v_count = 0 THEN
    RAISE NOTICE '  ✅ ไม่มี — ตรงกับภาพ ครม. 14 รายการเป๊ะ';
  ELSE
    RAISE NOTICE '';
    RAISE NOTICE '  → ลบรายการเหล่านี้ผ่าน UI ที่หน้า "วันหยุดประเพณี" (ปุ่ม "ลบ")';
    RAISE NOTICE '  → หรือ uncomment DELETE block ใน migration นี้';
  END IF;
END $$;

-- ════════ Optional: DELETE รายการที่เกิน (uncomment ถ้าไม่กลัว cascade) ════════
-- ⚠ ถ้ามี holiday_swap_requests อ้างถึง row ที่ลบ — จะถูก CASCADE ลบไปด้วย
-- เปิด comment ออก (ลบ -- หน้าแต่ละบรรทัด) แล้วรันใหม่
--
-- DELETE FROM public.calendar_items
-- WHERE date >= '2026-01-01' AND date <= '2026-12-31'
--   AND type = 'holiday'
--   AND date::TEXT NOT IN (
--     '2026-01-01','2026-03-03','2026-04-06','2026-04-13','2026-04-14','2026-04-15',
--     '2026-05-01','2026-06-03','2026-07-28','2026-08-12','2026-10-13','2026-10-23',
--     '2026-12-05','2026-12-31'
--   );
