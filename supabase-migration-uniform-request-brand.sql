-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Brand Preference ใน uniform_requests
--
-- รองรับ:
--   - Recruit form: HR ระบุแบรนด์ที่ต้องการให้ผู้สมัคร (optional)
--   - Self-service: พนักงานเลือกแบรนด์ (ถ้ารู้)
--   - HR direct: เลือกแบรนด์ตอนสร้างคำขอ
--   - Issue form: filter items ตาม brand_preference อัตโนมัติ
--
-- ทำให้:
--   - เปิดแบรนด์ใหม่ → คำขอใหม่เลือกแบรนด์ใหม่ได้ทันที
--   - HR ไม่ต้องเดาแบรนด์ตอนจัดชุด
--   - คำขอเก่า (brand_preference = NULL) → ทำงานเหมือนเดิม (เลือกแบรนด์ใดก็ได้)
--
-- รันใน Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.uniform_requests
  ADD COLUMN IF NOT EXISTS brand_preference TEXT;

CREATE INDEX IF NOT EXISTS idx_uniform_requests_brand ON public.uniform_requests(brand_preference);

NOTIFY pgrst, 'reload schema';

DO $$
DECLARE v_count INT;
BEGIN
  SELECT count(*) INTO v_count FROM public.uniform_requests;
  RAISE NOTICE '✅ brand_preference column ติดตั้งแล้ว';
  RAISE NOTICE '   uniform_requests มี % รายการ (brand_preference = NULL สำหรับคำขอเก่า)', v_count;
  RAISE NOTICE '   คำขอใหม่: HR/พนักงานเลือกแบรนด์ได้ (optional)';
END $$;
