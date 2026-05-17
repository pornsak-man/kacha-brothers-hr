-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Recruit System
-- ตาราง applicants (ผู้สมัครงาน) + RLS + realtime
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ── ผู้สมัครงาน ──
CREATE TABLE IF NOT EXISTS public.applicants (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  first_name        TEXT NOT NULL,
  last_name         TEXT,
  nickname          TEXT,
  phone             TEXT,
  email             TEXT,
  position          TEXT REFERENCES public.position_levels(id) ON DELETE SET NULL,
  position_title    TEXT,
  department        TEXT REFERENCES public.departments(id) ON DELETE SET NULL,
  branch            TEXT,
  expected_salary   NUMERIC(12,2) DEFAULT 0,
  source            TEXT,
  status            TEXT NOT NULL DEFAULT 'new'
    CHECK (status IN ('new','screening','interviewed','passed','rejected','hired')),
  applied_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  interview_date    DATE,
  decided_date      DATE,
  hired_employee_id TEXT REFERENCES public.employees(id) ON DELETE SET NULL,
  note              TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_applicants_status   ON public.applicants(status);
CREATE INDEX IF NOT EXISTS idx_applicants_applied  ON public.applicants(applied_date DESC);
CREATE INDEX IF NOT EXISTS idx_applicants_position ON public.applicants(position);

-- ── RLS ──
ALTER TABLE public.applicants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "read_authenticated" ON public.applicants;
DROP POLICY IF EXISTS "write_admin"        ON public.applicants;

CREATE POLICY "read_authenticated" ON public.applicants
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "write_admin" ON public.applicants
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ── Realtime publication ──
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'applicants'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.applicants;
  END IF;
END $$;

-- ── Auto-update updated_at ──
CREATE OR REPLACE FUNCTION public.applicants_set_updated_at()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS on_applicants_updated ON public.applicants;
CREATE TRIGGER on_applicants_updated
  BEFORE UPDATE ON public.applicants
  FOR EACH ROW EXECUTE FUNCTION public.applicants_set_updated_at();

-- ═══════════════════════════════════════════════════════════
-- Status workflow:
--   new          = สมัครใหม่ (เพิ่งรับใบสมัคร)
--   screening    = นัดสัมภาษณ์ (กำหนดวันแล้ว)
--   interviewed  = สัมภาษณ์แล้ว (รอตัดสินใจ)
--   passed       = ผ่านการคัดเลือก (รอเริ่มงาน)
--   rejected     = ไม่ผ่าน
--   hired        = รับเข้าทำงาน (มี hired_employee_id แล้ว)
-- ═══════════════════════════════════════════════════════════
