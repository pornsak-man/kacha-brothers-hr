-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Security Fix M3: เพิ่ม permission check ใน check_blacklist
--
-- ปัญหาเดิม (blacklist.sql line 95-126):
--   - check_blacklist เป็น SECURITY DEFINER + GRANT EXECUTE TO authenticated
--   - ใครก็เรียก check_blacklist('1234567890123') ได้ → รู้ว่าใครติด blacklist
--   - ฐาน table employee_blacklist มี RLS ที่ require is_hr_or_admin()
--     แต่ RPC bypass RLS ผ่าน SECURITY DEFINER → คน non-HR เห็นข้อมูล HR ผ่าน RPC
--   - กรณีใช้งาน: branch_staff สงสัย → ยิง RPC ดู → รู้ว่าคนนั้นเคยถูก blacklist
--     เพื่ออะไรก็ตาม (gossip, discrimination, social engineering)
--
-- การแก้:
--   - แปลง SQL function → PL/pgSQL เพื่อใส่ permission check
--   - ใช้ user_has_permission('applicant.manage') ตาม seed Phase 1
--     (HR/admin มี perm นี้ — ส่วนคนอื่นไม่มี = block)
--   - ถ้า user_has_permission ยังไม่มีในระบบ → fallback เป็น is_hr_or_admin()
--
-- รันใน Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.check_blacklist(TEXT);

CREATE OR REPLACE FUNCTION public.check_blacklist(p_national_id TEXT)
RETURNS TABLE (
  id              BIGINT,
  national_id     TEXT,
  full_name       TEXT,
  nickname        TEXT,
  previous_emp_id TEXT,
  reason          TEXT,
  category        TEXT,
  severity        TEXT,
  review_date     DATE,
  notes           TEXT,
  created_at      TIMESTAMPTZ,
  created_by      TEXT
)
LANGUAGE PLPGSQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_has_perm BOOLEAN := FALSE;
BEGIN
  -- 1) ลอง user_has_permission('applicant.manage') ถ้ามี (Phase 1 matrix)
  BEGIN
    SELECT public.user_has_permission('applicant.manage') INTO v_has_perm;
  EXCEPTION WHEN OTHERS THEN
    -- function ไม่มี → fallback
    v_has_perm := NULL;
  END;

  -- 2) ถ้า user_has_permission ไม่มีในระบบ → fallback เป็น is_hr_or_admin()
  IF v_has_perm IS NULL THEN
    v_has_perm := public.is_hr_or_admin();
  END IF;

  IF NOT v_has_perm THEN
    RAISE EXCEPTION 'ไม่มีสิทธิ์ตรวจ blacklist (ต้องเป็น HR/admin หรือมี permission applicant.manage)';
  END IF;

  RETURN QUERY
    SELECT
      b.id, b.national_id, b.full_name, b.nickname, b.previous_emp_id,
      b.reason, b.category, b.severity, b.review_date, b.notes,
      b.created_at, b.created_by
    FROM public.employee_blacklist b
    WHERE b.national_id = p_national_id
      AND b.removed_at IS NULL
      AND (b.severity <> 'temporary' OR b.review_date IS NULL OR b.review_date >= CURRENT_DATE)
    ORDER BY b.created_at DESC;
END $$;

GRANT EXECUTE ON FUNCTION public.check_blacklist(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Security Fix M3 รัน เสร็จแล้ว';
  RAISE NOTICE '   - check_blacklist เช็ค user_has_permission(applicant.manage) ก่อน';
  RAISE NOTICE '   - fallback ไป is_hr_or_admin() ถ้า matrix ยังไม่มี';
  RAISE NOTICE '   - non-HR เรียกแล้ว → throw exception';
END $$;
