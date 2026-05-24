-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: 3-step approval chain
-- (สำหรับ leave_requests + holiday_swap_requests)
--
-- Workflow ใหม่:
--   1. ผู้จัดการสาขา (BM) เห็นชอบ/ไม่เห็นชอบ
--   2. Area Manager (AM) เห็นชอบ/ไม่เห็นชอบ
--   3. ผู้อนุมัติ final:
--      - ลา/swap < 3 วันต่อเนื่อง → AM อนุมัติ
--      - ลา/swap ≥ 3 วันต่อเนื่อง → Operation Manager (OM) อนุมัติ
--   HR/admin override ทุกขั้น
--
-- รันใน Supabase SQL Editor ครั้งเดียว — idempotent
-- ═══════════════════════════════════════════════════════════

-- ─── 1. leave_requests: เพิ่ม chain columns ────────────────
ALTER TABLE public.leave_requests
  ADD COLUMN IF NOT EXISTS bm_status          TEXT DEFAULT 'pending' CHECK (bm_status IN ('pending', 'endorsed', 'declined')),
  ADD COLUMN IF NOT EXISTS bm_by              UUID,
  ADD COLUMN IF NOT EXISTS bm_at              TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS bm_note            TEXT,
  ADD COLUMN IF NOT EXISTS am_status          TEXT DEFAULT 'pending' CHECK (am_status IN ('pending', 'endorsed', 'declined')),
  ADD COLUMN IF NOT EXISTS am_by              UUID,
  ADD COLUMN IF NOT EXISTS am_at              TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS am_note            TEXT,
  ADD COLUMN IF NOT EXISTS final_approver_role TEXT CHECK (final_approver_role IN ('am', 'om'));

CREATE INDEX IF NOT EXISTS idx_leave_bm_status ON public.leave_requests(bm_status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_leave_am_status ON public.leave_requests(am_status) WHERE status = 'pending';

-- ─── 2. holiday_swap_requests: เพิ่ม chain columns ──────────
ALTER TABLE public.holiday_swap_requests
  ADD COLUMN IF NOT EXISTS bm_status          TEXT DEFAULT 'pending' CHECK (bm_status IN ('pending', 'endorsed', 'declined')),
  ADD COLUMN IF NOT EXISTS bm_by              UUID,
  ADD COLUMN IF NOT EXISTS bm_at              TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS bm_note            TEXT,
  ADD COLUMN IF NOT EXISTS am_status          TEXT DEFAULT 'pending' CHECK (am_status IN ('pending', 'endorsed', 'declined')),
  ADD COLUMN IF NOT EXISTS am_by              UUID,
  ADD COLUMN IF NOT EXISTS am_at              TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS am_note            TEXT,
  ADD COLUMN IF NOT EXISTS final_approver_role TEXT CHECK (final_approver_role IN ('am', 'om'));

CREATE INDEX IF NOT EXISTS idx_swap_bm_status ON public.holiday_swap_requests(bm_status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_swap_am_status ON public.holiday_swap_requests(am_status) WHERE status = 'pending';

-- ─── Backfill ข้อมูลเก่า — กรณีที่อนุมัติแล้ว ──────────────
-- ถือว่าผ่าน chain ครบทุกขั้นแล้ว (legacy)
UPDATE public.leave_requests
SET bm_status = 'endorsed', am_status = 'endorsed',
    final_approver_role = COALESCE(final_approver_role, 'am')
WHERE status = 'approved' AND bm_status = 'pending';

UPDATE public.leave_requests
SET bm_status = 'declined'
WHERE status = 'rejected' AND bm_status = 'pending';

UPDATE public.holiday_swap_requests
SET bm_status = 'endorsed', am_status = 'endorsed',
    final_approver_role = COALESCE(final_approver_role, 'am')
WHERE status = 'approved' AND bm_status = 'pending';

UPDATE public.holiday_swap_requests
SET bm_status = 'declined'
WHERE status = 'rejected' AND bm_status = 'pending';

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Chain workflow columns เพิ่มเรียบร้อย';
  RAISE NOTICE '   - bm_status / am_status: pending → endorsed / declined';
  RAISE NOTICE '   - final_approver_role: am (เมื่อ <3 วันต่อเนื่อง) / om (≥3 วัน)';
  RAISE NOTICE '   - status เดิม: pending → approved / rejected (ใช้ตัดสินใจ final)';
  RAISE NOTICE '   - Backfill: คำขอที่อนุมัติแล้วก่อนหน้านี้ → ถือว่าผ่าน chain ครบ';
END $$;
