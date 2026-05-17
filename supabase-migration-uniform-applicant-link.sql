-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Link uniform_request → applicant
-- รองรับ flow: Recruit → Benefit → Payroll (hire)
-- คำขอจัดชุดสร้างตั้งแต่ตอนเพิ่มผู้สมัคร (ก่อนจะมี employee_id)
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent)
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.uniform_requests
  ADD COLUMN IF NOT EXISTS applicant_id UUID REFERENCES public.applicants(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_uniform_requests_applicant ON public.uniform_requests(applicant_id);

NOTIFY pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════
-- Flow ใหม่:
--   Recruit  → เพิ่มผู้สมัคร + ข้อมูลการจัดชุด (auto-create uniform_request, employee_id=NULL)
--   Benefit  → เห็นคำขอ → จัดชุด → status=issued
--   Payroll  → "รับเข้าทำงาน" → สร้าง employee + uniform_request.employee_id = new_emp_id
-- ═══════════════════════════════════════════════════════════
