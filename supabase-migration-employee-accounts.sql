-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Employee Account Management
-- สร้าง auth account ให้พนักงานทั้งหมดผ่าน RPC function
-- รูปแบบ: email = {id}@kacha.local · password เริ่มต้น = {id} · role = viewer
-- พนักงานเปลี่ยนรหัสได้เอง (มี UI อยู่แล้ว) · admin reset ได้
-- ═══════════════════════════════════════════════════════════

-- ต้องการ pgcrypto สำหรับ hash password (crypt + gen_salt)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─── สร้างบัญชีให้พนักงาน 1 คน ─────────────────────────────
CREATE OR REPLACE FUNCTION public.create_employee_account(p_employee_id TEXT)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid       UUID;
  v_email     TEXT;
  v_password  TEXT;
  v_name      TEXT;
  v_existing  UUID;
BEGIN
  -- เฉพาะ admin
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ต้องเป็น admin เท่านั้น';
  END IF;

  -- ตรวจ employee มีจริง
  SELECT id INTO v_uid FROM public.employees WHERE id = p_employee_id;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'ไม่พบพนักงานรหัส %', p_employee_id;
  END IF;
  v_uid := NULL;

  v_email := lower(p_employee_id) || '@kacha.local';
  v_password := p_employee_id;

  -- ถ้ามีบัญชีอยู่แล้ว — แค่คืน user_id เดิม + link ให้แน่ใจ
  SELECT id INTO v_existing FROM auth.users WHERE email = v_email;
  IF v_existing IS NOT NULL THEN
    UPDATE public.user_profiles SET employee_id = p_employee_id WHERE user_id = v_existing AND (employee_id IS NULL OR employee_id != p_employee_id);
    RETURN jsonb_build_object('user_id', v_existing, 'email', v_email, 'created', false, 'message', 'บัญชีมีอยู่แล้ว');
  END IF;

  SELECT trim(first_name || ' ' || COALESCE(last_name, '')) INTO v_name
    FROM public.employees WHERE id = p_employee_id;

  v_uid := gen_random_uuid();

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    v_uid, 'authenticated', 'authenticated', v_email,
    crypt(v_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('employee_id', p_employee_id, 'name', v_name),
    now(), now()
  );

  -- ใส่ identity record (Supabase ต้องการสำหรับ login ด้วย email/password)
  INSERT INTO auth.identities (
    id, user_id, identity_data, provider, provider_id,
    last_sign_in_at, created_at, updated_at
  ) VALUES (
    gen_random_uuid(), v_uid,
    jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true),
    'email', v_email, NULL, now(), now()
  );

  -- handle_new_user trigger สร้าง user_profile แล้ว — link กับ employee
  UPDATE public.user_profiles SET employee_id = p_employee_id WHERE user_id = v_uid;

  RETURN jsonb_build_object('user_id', v_uid, 'email', v_email, 'created', true, 'message', 'สร้างบัญชีสำเร็จ');
END $$;

-- ─── สร้างบัญชีให้พนักงานทั้งหมดที่ยังไม่มีบัญชี ───────────────
CREATE OR REPLACE FUNCTION public.bulk_create_employee_accounts()
RETURNS TABLE(employee_id TEXT, email TEXT, created BOOLEAN, message TEXT)
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  emp RECORD;
  v_result JSONB;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ต้องเป็น admin เท่านั้น';
  END IF;

  FOR emp IN
    SELECT e.id
    FROM public.employees e
    LEFT JOIN public.user_profiles up ON up.employee_id = e.id
    WHERE up.user_id IS NULL
      AND COALESCE(e.status, 'active') != 'resigned'
    ORDER BY e.id
  LOOP
    BEGIN
      v_result := public.create_employee_account(emp.id);
      employee_id := emp.id;
      email := v_result->>'email';
      created := (v_result->>'created')::BOOLEAN;
      message := v_result->>'message';
      RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      employee_id := emp.id;
      email := lower(emp.id) || '@kacha.local';
      created := false;
      message := 'ERROR: ' || SQLERRM;
      RETURN NEXT;
    END;
  END LOOP;
END $$;

-- ─── Admin reset รหัสผ่านของพนักงาน ────────────────────────
CREATE OR REPLACE FUNCTION public.reset_employee_password(p_employee_id TEXT, p_new_password TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid      UUID;
  v_password TEXT;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ต้องเป็น admin เท่านั้น';
  END IF;

  -- ถ้าไม่ระบุ — ใช้ employee_id เป็น default (เหมือนตอนสร้างใหม่)
  v_password := COALESCE(NULLIF(trim(p_new_password), ''), p_employee_id);

  SELECT user_id INTO v_uid FROM public.user_profiles WHERE employee_id = p_employee_id;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'ไม่พบบัญชีของพนักงาน %', p_employee_id;
  END IF;

  UPDATE auth.users
  SET encrypted_password = crypt(v_password, gen_salt('bf')),
      updated_at = now()
  WHERE id = v_uid;

  RETURN jsonb_build_object('user_id', v_uid, 'password', v_password, 'message', 'รีเซ็ตรหัสผ่านสำเร็จ');
END $$;

-- ─── Admin ตั้ง role ของพนักงาน (admin/viewer) ──────────────
CREATE OR REPLACE FUNCTION public.set_employee_role(p_employee_id TEXT, p_role TEXT)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ต้องเป็น admin เท่านั้น';
  END IF;
  IF p_role NOT IN ('admin', 'viewer') THEN
    RAISE EXCEPTION 'role ต้องเป็น admin หรือ viewer';
  END IF;

  UPDATE public.user_profiles SET role = p_role WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบบัญชีของพนักงาน %', p_employee_id;
  END IF;

  RETURN jsonb_build_object('employee_id', p_employee_id, 'role', p_role);
END $$;

GRANT EXECUTE ON FUNCTION public.create_employee_account(TEXT)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.bulk_create_employee_accounts()       TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_employee_password(TEXT, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_employee_role(TEXT, TEXT)         TO authenticated;

NOTIFY pgrst, 'reload schema';
