-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Security Fix Batch (2026-05-26)
--
-- แก้ปัญหา Critical 4 + High-impact 1:
--   C-1: create_employee_user return plaintext password (regression C2)
--   C-2: SECURITY DEFINER functions ไม่มี SET search_path (schema hijack)
--   C-3: audit_log publish ไป realtime → leak PII ผ่าน WebSocket
--   M-2: cross_branch_borrow_requests INSERT ข้าม approval workflow
--   H-A3: bulkCreateEmployeeAccounts return plaintext (แก้ใน data.js แยก)
--
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ════════ C-1: create_employee_user — drop password from response ════════
-- คืน user_id + email + ธง needs_change เท่านั้น
-- HR ต้องใช้ "reset password" workflow แยก หรือบอก default password ผ่านช่องทางอื่น
DO $$
DECLARE v_exists BOOL;
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'create_employee_user'
  ) INTO v_exists;
  IF NOT v_exists THEN
    RAISE NOTICE 'ℹ create_employee_user ยังไม่มี — ข้าม C-1';
    RETURN;
  END IF;

  EXECUTE $body$
    CREATE OR REPLACE FUNCTION public.create_employee_user(
      p_employee_id TEXT,
      p_password    TEXT DEFAULT NULL
    )
    RETURNS JSONB
    LANGUAGE PLPGSQL
    SECURITY DEFINER
    SET search_path = public, auth, extensions
    AS $inner$
    DECLARE
      v_email        TEXT;
      v_password     TEXT;
      v_first        TEXT;
      v_last         TEXT;
      v_fullname     TEXT;
      v_existing_uid UUID;
      v_msg          TEXT;
    BEGIN
      IF NOT public.user_has_permission('user.create_account') THEN
        RAISE EXCEPTION 'ไม่มีสิทธิ์สร้างบัญชีผู้ใช้' USING ERRCODE = '42501';
      END IF;

      SELECT first_name, last_name INTO v_first, v_last
      FROM public.employees WHERE id = p_employee_id;
      IF v_first IS NULL THEN
        RAISE EXCEPTION 'ไม่พบพนักงาน %', p_employee_id;
      END IF;

      v_email := lower(p_employee_id) || '@kacha.local';
      v_password := COALESCE(
        NULLIF(trim(p_password), ''),
        regexp_replace(COALESCE((SELECT national_id FROM public.employees WHERE id = p_employee_id), ''), '\D', '', 'g'),
        p_employee_id
      );
      v_fullname := trim(COALESCE(v_first,'') || ' ' || COALESCE(v_last,''));

      SELECT id INTO v_existing_uid FROM auth.users WHERE email = v_email;
      IF v_existing_uid IS NOT NULL THEN
        INSERT INTO public.user_profiles (user_id, employee_id, role, force_password_change)
        VALUES (v_existing_uid, p_employee_id, COALESCE((SELECT role FROM public.user_profiles WHERE user_id = v_existing_uid), 'viewer'), false)
        ON CONFLICT (user_id) DO UPDATE SET employee_id = EXCLUDED.employee_id;
        RETURN jsonb_build_object(
          'email', v_email, 'source', 'linked-existing',
          'created', false, 'user_id', v_existing_uid, 'needs_change', false
        );
      END IF;

      INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
      VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', v_email, extensions.crypt(v_password, extensions.gen_salt('bf')), now(), jsonb_build_object('provider','email','providers',ARRAY['email']), jsonb_build_object('full_name', v_fullname), now(), now(), '', '', '', '')
      RETURNING id INTO v_existing_uid;

      -- ★ force_password_change=true → user ต้องตั้ง password ใหม่ตอน first login
      INSERT INTO public.user_profiles (user_id, employee_id, role, force_password_change)
      VALUES (v_existing_uid, p_employee_id, 'viewer', true);

      -- ★ NO LONGER returns password — caller ต้องใช้ default (NID) ตรง ๆ
      --   หรือ HR สร้าง one-time link ผ่าน workflow แยก
      RETURN jsonb_build_object(
        'email', v_email, 'source', 'created-new',
        'created', true, 'user_id', v_existing_uid,
        'needs_change', true,
        'password_hint', 'เลขบัตรประชาชน (13 หลัก ไม่มีขีด)'
      );
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      RAISE EXCEPTION 'create_employee_user fail: % (employee=%)', v_msg, p_employee_id;
    END $inner$;
  $body$;
  RAISE NOTICE '✅ C-1: create_employee_user — drop password field';
END $$;


-- ════════ C-2: SET search_path บน SECURITY DEFINER functions ที่ขาด ════════
-- ALTER FUNCTION pattern (ไม่ต้อง redefine body) — ใช้กับฟังก์ชันที่ source code อยู่ใน migration อื่น
DO $$
DECLARE
  v_fn TEXT;
  v_count INT := 0;
BEGIN
  -- list ของฟังก์ชันที่รู้ว่าขาด SET search_path
  FOR v_fn IN
    SELECT unnest(ARRAY[
      'public.current_user_role()',
      'public.current_user_employee_id()',
      'public.current_user_managed_branches()',
      'public.current_user_branch()',
      'public.can_read_employee_row(text)',
      'public.can_read_employee_financial(text)',
      'public.audit_trigger_fn()',
      'public.handle_new_user()'
    ])
  LOOP
    BEGIN
      EXECUTE format('ALTER FUNCTION %s SET search_path = public, pg_temp', v_fn);
      v_count := v_count + 1;
    EXCEPTION WHEN undefined_function THEN
      RAISE NOTICE 'ℹ function % ไม่มี — ข้าม', v_fn;
    WHEN OTHERS THEN
      RAISE NOTICE '⚠ ALTER FUNCTION % fail: %', v_fn, SQLERRM;
    END;
  END LOOP;
  RAISE NOTICE '✅ C-2: ALTER %s SECURITY DEFINER functions (set search_path=public,pg_temp)', v_count;
END $$;

-- audit_trigger_fn ต้อง SET search_path INCLUDE auth (อ้าง auth.uid + auth.users)
ALTER FUNCTION public.audit_trigger_fn() SET search_path = public, auth, pg_temp;


-- ════════ C-3: DROP audit_log จาก realtime publication ════════
-- audit_log มี PII (old_data/new_data ของ employees) — ไม่ควร stream ผ่าน WebSocket
-- หน้า audit_log อ่านผ่าน REST + manual refresh ก็พอ
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'audit_log'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.audit_log;
    RAISE NOTICE '✅ C-3: DROP audit_log จาก realtime — ไม่ leak PII ผ่าน WebSocket';
  ELSE
    RAISE NOTICE 'ℹ audit_log ไม่อยู่ใน realtime publication — ข้าม';
  END IF;
END $$;


-- ════════ M-2: borrow INSERT policy — ต้อง status='pending' + auto_approved=false ════════
-- กัน AM/BM ของ destination INSERT แถวที่ status='approved' โดยตรง (bypass review)
-- ถ้าจะ auto-approve ต้องผ่าน RPC create_borrow_request() ที่ตรวจสิทธิ์ source ก่อน
DROP POLICY IF EXISTS "borrow_insert" ON public.cross_branch_borrow_requests;
CREATE POLICY "borrow_insert" ON public.cross_branch_borrow_requests
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_hr_or_admin()
    OR (
      public.can_create_schedule_for_branch(destination_branch_id)
      AND status = 'pending'           -- ★ บังคับ pending — auto-approve ต้องผ่าน RPC
      AND auto_approved = false        -- ★ บังคับ false — RPC จะ flip เป็น true ตอนตรวจสิทธิ์ครบ
    )
  );


-- ════════ Final notice ════════
NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════';
  RAISE NOTICE '✅ Security Fix Batch (2026-05-26) ติดตั้งเสร็จ';
  RAISE NOTICE '';
  RAISE NOTICE 'แก้แล้ว:';
  RAISE NOTICE '  C-1: create_employee_user ไม่คืน password อีกแล้ว';
  RAISE NOTICE '  C-2: SECURITY DEFINER functions มี SET search_path';
  RAISE NOTICE '  C-3: audit_log ไม่ stream ผ่าน realtime แล้ว';
  RAISE NOTICE '  M-2: borrow INSERT ต้อง status=pending — กัน bypass review';
  RAISE NOTICE '';
  RAISE NOTICE 'ต้องแก้ frontend (data.js):';
  RAISE NOTICE '  - bulkCreateEmployeeAccounts: ไม่เก็บ password ใน result (H-A3)';
  RAISE NOTICE '  - HR workflow ใหม่: แสดง "password_hint" แทน plaintext password';
  RAISE NOTICE '═══════════════════════════════════════════';
END $$;
