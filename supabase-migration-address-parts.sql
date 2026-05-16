-- ═══════════════════════════════════════════════════════════
-- KHACHA BROTHERS HR — Migration: Address Parts
-- แยกที่อยู่เป็น แขวง/ตำบล, เขต/อำเภอ, จังหวัด
-- รันสคริปต์นี้ใน Supabase SQL Editor ครั้งเดียว
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS sub_district TEXT,
  ADD COLUMN IF NOT EXISTS district     TEXT,
  ADD COLUMN IF NOT EXISTS province     TEXT,
  ADD COLUMN IF NOT EXISTS postal_code  TEXT;
