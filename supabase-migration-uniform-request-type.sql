-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — เพิ่ม request_type + reason ใน uniform_requests
--
-- กฎทางธุรกิจ:
--   - พนักงานใหม่ (new_hire)  → ฟรี (บริษัทออก)
--   - ชุดเสีย (damaged)        → ฟรี (ถ้าเกิดจากงาน) / จ่ายเอง (ถ้าเอง)
--   - ชุดหาย (lost)            → จ่ายเอง (ตามนโยบาย)
--   - ครบรอบ (periodic)        → ฟรี (เปลี่ยนตามรอบ เช่น 1 ปี)
--   - ขอเพิ่ม (extra)          → จ่ายเอง
--
-- รันใน Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.uniform_requests
  ADD COLUMN IF NOT EXISTS request_type TEXT,
  ADD COLUMN IF NOT EXISTS request_reason TEXT;

-- CHECK constraint (drop ก่อน add ใหม่ — idempotent)
ALTER TABLE public.uniform_requests
  DROP CONSTRAINT IF EXISTS uniform_requests_request_type_check;
ALTER TABLE public.uniform_requests
  ADD CONSTRAINT uniform_requests_request_type_check
  CHECK (request_type IS NULL OR request_type IN (
    'new_hire',  -- พนักงานใหม่ (ฟรี)
    'damaged',   -- ชุดเสีย (ฟรี/จ่ายเอง ตามเคส)
    'lost',      -- ชุดหาย (จ่ายเอง)
    'periodic',  -- ครบรอบเปลี่ยน (ฟรี)
    'extra'      -- ขอเพิ่ม (จ่ายเอง)
  ));

COMMENT ON COLUMN public.uniform_requests.request_type IS
  'ประเภทคำขอ: new_hire=ฟรี · damaged=ตามเคส · lost=จ่ายเอง · periodic=ฟรี · extra=จ่ายเอง';
COMMENT ON COLUMN public.uniform_requests.request_reason IS
  'รายละเอียดเหตุผล (เช่น เสื้อขาดเพราะอุบัติเหตุ, ลืมที่ทำงาน ฯลฯ)';

CREATE INDEX IF NOT EXISTS idx_uniform_requests_type ON public.uniform_requests(request_type);

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ เพิ่ม column request_type + request_reason ใน uniform_requests';
  RAISE NOTICE '   - 5 types: new_hire / damaged / lost / periodic / extra';
  RAISE NOTICE '   - constraint: request_type IS NULL allowed (backward compat)';
  RAISE NOTICE '   - index: idx_uniform_requests_type';
END $$;
