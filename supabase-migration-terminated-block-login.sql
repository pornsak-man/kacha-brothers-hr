-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Auto-block พนักงานพ้นสภาพไม่ให้ login ที่ DB level
--
-- ปัจจุบัน: เมื่อ HR ตั้ง termination_date → client-side checkTerminationAndBlock()
--          จะ force logout ตอน login หรือ realtime sync
--          → แต่ถ้า user แอบเรียก auth API ตรงๆ ผ่าน console ก็ยังเข้าได้
--
-- แก้: Postgres trigger ที่ disable auth.users.banned_until = '2099-12-31'
--      เมื่อ employees.termination_date <= today
--      → revert (banned_until = NULL) เมื่อ termination_date ถูก clear
--
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — CREATE OR REPLACE)
-- ═══════════════════════════════════════════════════════════
-- ROLLBACK (paste เพื่อ undo):
--   DROP TRIGGER IF EXISTS trg_emp_terminated_block_auth ON public.employees;
--   DROP FUNCTION IF EXISTS public.sync_employee_termination_to_auth();
--   UPDATE auth.users SET banned_until = NULL WHERE banned_until = '2099-12-31 00:00:00+00';
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.sync_employee_termination_to_auth()
RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE
  v_user_id UUID;
  v_today DATE := (now() AT TIME ZONE 'Asia/Bangkok')::date;
  v_old_terminated BOOLEAN;
  v_new_terminated BOOLEAN;
BEGIN
  -- หา user_id ที่ผูกกับพนักงานคนนี้
  SELECT user_id INTO v_user_id
  FROM public.user_profiles
  WHERE employee_id = NEW.id;
  IF v_user_id IS NULL THEN
    -- พนักงานไม่มี user account ผูกอยู่ → ไม่ต้องทำอะไร
    RETURN NEW;
  END IF;

  v_old_terminated := (TG_OP = 'UPDATE' AND OLD.termination_date IS NOT NULL AND OLD.termination_date <= v_today);
  v_new_terminated := (NEW.termination_date IS NOT NULL AND NEW.termination_date <= v_today);

  -- เพิ่ง terminate (active → terminated)
  IF v_new_terminated AND NOT v_old_terminated THEN
    UPDATE auth.users
    SET banned_until = '2099-12-31 00:00:00+00'::timestamptz
    WHERE id = v_user_id;
    RAISE NOTICE 'Blocked auth.users.id=% (employee %)', v_user_id, NEW.id;

  -- ยกเลิก termination (terminated → active)
  ELSIF v_old_terminated AND NOT v_new_terminated THEN
    UPDATE auth.users
    SET banned_until = NULL
    WHERE id = v_user_id;
    RAISE NOTICE 'Unblocked auth.users.id=% (employee %)', v_user_id, NEW.id;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- ถ้า auth.users update ไม่ได้ (เช่น permission issue) ก็ไม่ block การ save employee
  -- client-side block ยังมีอยู่ + admin สามารถ disable ผ่าน Supabase dashboard ได้
  RAISE NOTICE 'sync_employee_termination_to_auth fail: % (employee %)', SQLERRM, NEW.id;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_emp_terminated_block_auth ON public.employees;
CREATE TRIGGER trg_emp_terminated_block_auth
  AFTER INSERT OR UPDATE OF termination_date ON public.employees
  FOR EACH ROW EXECUTE FUNCTION public.sync_employee_termination_to_auth();

-- ─── BACKFILL — sync state ปัจจุบัน (รัน 1 ครั้งหลัง create trigger) ───
DO $$
DECLARE
  v_today DATE := (now() AT TIME ZONE 'Asia/Bangkok')::date;
  v_count_blocked INTEGER := 0;
  v_count_unblocked INTEGER := 0;
BEGIN
  -- Block: พนักงานพ้นสภาพแล้วแต่ auth ยังไม่ banned
  WITH to_block AS (
    SELECT up.user_id
    FROM public.user_profiles up
    JOIN public.employees e ON e.id = up.employee_id
    WHERE e.termination_date IS NOT NULL
      AND e.termination_date <= v_today
  )
  UPDATE auth.users u
  SET banned_until = '2099-12-31 00:00:00+00'::timestamptz
  FROM to_block tb
  WHERE u.id = tb.user_id
    AND (u.banned_until IS NULL OR u.banned_until < now());
  GET DIAGNOSTICS v_count_blocked = ROW_COUNT;

  -- Unblock: เคย banned แต่ตอนนี้ไม่ terminated
  WITH still_active AS (
    SELECT up.user_id
    FROM public.user_profiles up
    JOIN public.employees e ON e.id = up.employee_id
    WHERE e.termination_date IS NULL OR e.termination_date > v_today
  )
  UPDATE auth.users u
  SET banned_until = NULL
  FROM still_active sa
  WHERE u.id = sa.user_id
    AND u.banned_until = '2099-12-31 00:00:00+00'::timestamptz;
  GET DIAGNOSTICS v_count_unblocked = ROW_COUNT;

  RAISE NOTICE '✅ Backfill เสร็จสิ้น: blocked=%, unblocked=%', v_count_blocked, v_count_unblocked;
END $$;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Trigger ติดตั้งสำเร็จ';
  RAISE NOTICE '   พ้นสภาพ (termination_date <= today) → banned_until = 2099-12-31 → login ไม่ได้';
  RAISE NOTICE '   ยกเลิกพ้นสภาพ → banned_until = NULL → login ได้ปกติ';
  RAISE NOTICE '   ทำงานทั้ง INSERT/UPDATE — fail-safe (ไม่ block save ถ้า auth update fail)';
END $$;

-- ═══════════════════════════════════════════════════════════
-- TEST CASES:
--   1. ตั้ง termination_date = today ของพนักงานคนหนึ่ง → save
--      → user คนนั้น logout/login ใหม่ → error "Invalid credentials"
--   2. ลบ termination_date (active กลับ) → save
--      → login ได้ปกติ
--   3. ตั้ง termination_date = future (เช่น พ.ค. 2570) → ไม่ block (รอถึงวันจริง)
--      ⚠️ caveat: ไม่มี cron — ต้อง run backfill block อีกครั้งเมื่อถึงวันนั้น
--                หรือใช้ scheduled function ของ Supabase (pg_cron)
-- ═══════════════════════════════════════════════════════════
