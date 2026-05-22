-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Seed: ฝ่ายเพิ่มเติมสำหรับธุรกิจ F&B
-- เพิ่ม 6 ฝ่าย: ครัว / บริการลูกค้า / จัดซื้อ / คลังสินค้า / ไอที / ซ่อมบำรุง
-- รันใน Supabase SQL Editor (idempotent — ON CONFLICT DO NOTHING)
-- รวมกับ D001-D005 เดิม → 11 ฝ่ายทั้งหมด
-- ═══════════════════════════════════════════════════════════

INSERT INTO public.departments (id, name, note) VALUES
  ('D006', 'ฝ่ายครัว',           'Kitchen — เชฟ ผู้ช่วยเชฟ ผู้เตรียมอาหาร'),
  ('D007', 'ฝ่ายบริการลูกค้า',   'Service — พนักงานเสิร์ฟ พนักงานต้อนรับ แคชเชียร์'),
  ('D008', 'ฝ่ายจัดซื้อ',         'Purchasing — จัดซื้อวัตถุดิบและพัสดุ'),
  ('D009', 'ฝ่ายคลังสินค้า',     'Warehouse — รับ-เบิก-ตรวจนับสต็อก'),
  ('D010', 'ฝ่ายไอที',            'IT — ดูแลระบบ POS, network, อุปกรณ์'),
  ('D011', 'ฝ่ายซ่อมบำรุง',      'Maintenance — บำรุงรักษาอุปกรณ์ + อาคาร')
ON CONFLICT (id) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ─── รายงานผล ───
DO $$
DECLARE
  v_total INTEGER;
  v_added INTEGER;
  r RECORD;
BEGIN
  SELECT COUNT(*) INTO v_total FROM public.departments;
  SELECT COUNT(*) INTO v_added FROM public.departments WHERE id IN ('D006','D007','D008','D009','D010','D011');
  RAISE NOTICE '═══ ฝ่ายในระบบหลัง migration ═══';
  RAISE NOTICE 'รวมทั้งหมด: % ฝ่าย', v_total;
  RAISE NOTICE 'ฝ่ายที่ตั้งใจเพิ่ม (D006-D011) มีในระบบ: %/6', v_added;
  RAISE NOTICE '';
  RAISE NOTICE 'รายการฝ่ายทั้งหมด:';
  FOR r IN SELECT id, name FROM public.departments ORDER BY id LOOP
    RAISE NOTICE '  % = %', r.id, r.name;
  END LOOP;
  IF v_added = 6 THEN
    RAISE NOTICE '✅ สำเร็จ — ครบ 6 ฝ่ายใหม่';
  ELSE
    RAISE WARNING '⚠️ มีบางฝ่ายไม่ครบ — ตรวจสอบ';
  END IF;
END $$;
