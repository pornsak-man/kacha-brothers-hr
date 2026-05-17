-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Uniform Delivery Schedule
-- รอบการจัดส่งชุดพนักงานต่อสาขา (เช่น KMB ส่งวันพุธ)
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.uniform_delivery_schedule (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  branch_code  TEXT NOT NULL,                 -- รหัส/ชื่อย่อสาขา เช่น "KMB"
  day_of_week  INTEGER NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  -- 0=อาทิตย์ 1=จันทร์ 2=อังคาร 3=พุธ 4=พฤหัสบดี 5=ศุกร์ 6=เสาร์
  active       BOOLEAN DEFAULT true,
  note         TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(branch_code, day_of_week)
);
CREATE INDEX IF NOT EXISTS idx_uniform_schedule_branch ON public.uniform_delivery_schedule(branch_code);

-- RLS
ALTER TABLE public.uniform_delivery_schedule ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "read_authenticated" ON public.uniform_delivery_schedule;
DROP POLICY IF EXISTS "write_admin"        ON public.uniform_delivery_schedule;
CREATE POLICY "read_authenticated" ON public.uniform_delivery_schedule FOR SELECT TO authenticated USING (true);
CREATE POLICY "write_admin"        ON public.uniform_delivery_schedule FOR ALL    TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Realtime
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'uniform_delivery_schedule'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.uniform_delivery_schedule;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
