-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Branches master
-- ตารางสาขา (master list) — แทนการเก็บเป็น text อิสระในตาราง employees
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.branches (
  id          TEXT PRIMARY KEY,             -- รหัสสาขา (เช่น KMB, GE, JM) — ใช้เป็น PK
  name        TEXT,                          -- ชื่อเต็มสาขา (optional)
  active      BOOLEAN DEFAULT true,
  note        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_branches_active ON public.branches(active);

-- RLS
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_authenticated" ON public.branches;
DROP POLICY IF EXISTS "write_admin"        ON public.branches;
CREATE POLICY "read_authenticated" ON public.branches FOR SELECT TO authenticated USING (true);
CREATE POLICY "write_admin"        ON public.branches FOR ALL    TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Realtime
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'branches'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.branches;
  END IF;
END $$;

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION public.branches_set_updated_at()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

DROP TRIGGER IF EXISTS on_branches_updated ON public.branches;
CREATE TRIGGER on_branches_updated BEFORE UPDATE ON public.branches
  FOR EACH ROW EXECUTE FUNCTION public.branches_set_updated_at();

-- ── Seed 34 สาขา (จากข้อมูลจริง) ──
INSERT INTO public.branches (id) VALUES
  ('GE'), ('JD'), ('JI'), ('JP'), ('JT'),
  ('K2'), ('K21'), ('K3'), ('K9'),
  ('KA'), ('KC'), ('KE'), ('KF'), ('KG'), ('KGS'),
  ('KI'), ('KK'), ('KL'), ('KM'), ('KMB'),
  ('KP'), ('KR'), ('KSD'), ('KSE'),
  ('KT'), ('KU'), ('KW'), ('KW2'), ('KY'),
  ('ND'), ('OY'), ('ZE'), ('ZL'), ('ZP')
ON CONFLICT (id) DO NOTHING;

NOTIFY pgrst, 'reload schema';
