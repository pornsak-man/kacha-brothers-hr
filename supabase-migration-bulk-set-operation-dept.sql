-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — One-off: ตั้งฝ่ายพนักงานทุกคนเป็น "ฝ่ายปฏิบัติการ" (D005)
-- ขอบเขต: ทุกคนในตาราง employees (รวมพ้นสภาพ)
-- ─────────────────────────────────────────────────────────────
-- วิธีใช้:
--   1) เปิด Supabase Dashboard → SQL Editor
--   2) วาง SQL นี้ทั้งไฟล์ → กด Run
--   3) ดูผลใน NOTICE log — จะบอกว่ามี/จะ update กี่ row
-- รันซ้ำได้ปลอดภัย (idempotent — รอบ 2 จะ 0 row)
-- ═══════════════════════════════════════════════════════════

-- ─── 1) ตรวจสอบก่อน UPDATE — สรุปสถานะปัจจุบัน ───
DO $$
DECLARE
  v_target_exists BOOLEAN;
  v_target_name TEXT;
  v_total INTEGER;
  v_already INTEGER;
  v_other INTEGER;
  v_null INTEGER;
BEGIN
  -- ยืนยันว่ามี D005 อยู่ใน master
  SELECT EXISTS(SELECT 1 FROM public.departments WHERE id = 'D005') INTO v_target_exists;
  IF NOT v_target_exists THEN
    RAISE EXCEPTION '❌ ไม่พบฝ่าย "D005" ในตาราง departments — ยกเลิก';
  END IF;
  SELECT name INTO v_target_name FROM public.departments WHERE id = 'D005';
  SELECT COUNT(*) INTO v_total FROM public.employees;
  SELECT COUNT(*) INTO v_already FROM public.employees WHERE department = 'D005';
  SELECT COUNT(*) INTO v_other FROM public.employees WHERE department IS NOT NULL AND department <> 'D005';
  SELECT COUNT(*) INTO v_null FROM public.employees WHERE department IS NULL;

  RAISE NOTICE '═══ สถานะก่อน UPDATE ═══';
  RAISE NOTICE 'เป้าหมาย: D005 = %', v_target_name;
  RAISE NOTICE 'พนักงานทั้งหมด: % คน', v_total;
  RAISE NOTICE '  อยู่ฝ่าย D005 อยู่แล้ว: % คน (จะข้าม)', v_already;
  RAISE NOTICE '  อยู่ฝ่ายอื่น: % คน (จะย้ายมา D005)', v_other;
  RAISE NOTICE '  ยังไม่มีฝ่าย (NULL): % คน (จะเซ็ตเป็น D005)', v_null;
  RAISE NOTICE 'จำนวนที่จะ update รวม: % row', v_other + v_null;
END $$;

-- ─── 2) UPDATE จริง ───
UPDATE public.employees
SET department = 'D005'
WHERE department IS DISTINCT FROM 'D005';

-- ─── 3) ตรวจสอบผลลัพธ์หลัง UPDATE ───
DO $$
DECLARE
  v_total INTEGER;
  v_d005 INTEGER;
  v_other INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_total FROM public.employees;
  SELECT COUNT(*) INTO v_d005 FROM public.employees WHERE department = 'D005';
  SELECT COUNT(*) INTO v_other FROM public.employees WHERE department IS DISTINCT FROM 'D005';
  RAISE NOTICE '═══ ผลหลัง UPDATE ═══';
  RAISE NOTICE 'พนักงานทั้งหมด: % คน', v_total;
  RAISE NOTICE '  ฝ่าย D005: % คน', v_d005;
  RAISE NOTICE '  ฝ่ายอื่น (ควรเป็น 0): % คน', v_other;
  IF v_other = 0 THEN
    RAISE NOTICE '✅ สำเร็จ — ทุกคนอยู่ฝ่ายปฏิบัติการแล้ว';
  ELSE
    RAISE WARNING '⚠️ ยังมี % คนไม่อยู่ D005 — ตรวจสอบ', v_other;
  END IF;
END $$;
