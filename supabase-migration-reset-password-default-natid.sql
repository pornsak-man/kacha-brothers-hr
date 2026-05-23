-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Update: reset_employee_password default = เลขประชาชน
-- เดิม: ถ้า HR กด "รีเซ็ตรหัสผ่าน" โดยเว้นว่าง → default = employee_id
-- ใหม่: default = เลข ปชช ของพนักงาน → fallback employee_id ถ้าไม่มี ปชช
-- สอดคล้องกับนโยบายบริษัท: ใช้ ปชช เป็นรหัสผ่านเริ่มต้นทุกคน
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.reset_employee_password(p_employee_id TEXT, p_new_password TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
  v_uid       UUID;
  v_password  TEXT;
  v_natid     TEXT;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ต้องเป็น admin เท่านั้น';
  END IF;

  -- หาเลข ปชช เพื่อใช้เป็น default ถ้า HR ไม่ส่งรหัสผ่านใหม่มา
  SELECT regexp_replace(COALESCE(national_id, ''), '\D', '', 'g') INTO v_natid
  FROM public.employees WHERE id = p_employee_id;

  v_password := COALESCE(
    NULLIF(trim(p_new_password), ''),
    NULLIF(v_natid, ''),
    p_employee_id  -- fallback สุดท้ายถ้าไม่มี ปชช
  );

  SELECT user_id INTO v_uid FROM public.user_profiles WHERE employee_id = p_employee_id;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'ไม่พบบัญชีของพนักงาน %', p_employee_id;
  END IF;

  UPDATE auth.users
  SET encrypted_password = extensions.crypt(v_password, extensions.gen_salt('bf')),
      updated_at = now()
  WHERE id = v_uid;

  RETURN jsonb_build_object('user_id', v_uid, 'password', v_password, 'message', 'รีเซ็ตรหัสผ่านสำเร็จ');
END $$;

GRANT EXECUTE ON FUNCTION public.reset_employee_password(TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ reset_employee_password อัปเดตแล้ว';
  RAISE NOTICE '   - HR กด reset เว้นว่าง → default = เลข ปชช ของพนักงาน';
  RAISE NOTICE '   - ถ้าไม่มี ปชช → fallback = employee_id';
END $$;
