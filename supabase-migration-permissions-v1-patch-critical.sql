-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Patch: แก้ semantics ของ critical lock ใน set_role_permissions
--
-- Bug: เดิม RPC ใช้ logic "ทุก role ต้องมี critical perm ทุกตัว" → save HR ไม่ได้
--      เพราะ HR ไม่มี permission.edit_matrix (is_critical) → reject
--
-- Fix: "soft critical" — ถ้า role นี้เคย granted critical perm A แล้วจะปลด → reject
--      ถ้า role ไม่เคยมี ก็ไม่บังคับให้เพิ่ม
--
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — CREATE OR REPLACE)
-- ⚠️ ต้องรันหลังจาก supabase-migration-permissions-v1.sql แล้วเท่านั้น
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.set_role_permissions(
  p_role_id    TEXT,
  p_perm_keys  TEXT[]
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role  public.roles%ROWTYPE;
  v_lost  TEXT[];
BEGIN
  -- 1. authz: เฉพาะคนที่มี permission.edit_matrix
  IF NOT public.user_has_permission('permission.edit_matrix') THEN
    RAISE EXCEPTION 'ไม่มีสิทธิ์แก้ permission matrix';
  END IF;

  -- 2. role ต้องมีอยู่
  SELECT * INTO v_role FROM public.roles WHERE id = p_role_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ไม่พบ role: %', p_role_id;
  END IF;

  -- 3. ห้ามปิด critical permissions ที่ role นี้ "เคยมี" (soft critical — กัน lock-out)
  SELECT array_agg(rp.permission_key) INTO v_lost
  FROM public.role_permissions rp
  JOIN public.permissions p ON p.key = rp.permission_key
  WHERE rp.role_id = p_role_id
    AND rp.granted = true
    AND p.is_critical = true
    AND rp.permission_key <> ALL (p_perm_keys);
  IF v_lost IS NOT NULL AND array_length(v_lost, 1) > 0 THEN
    RAISE EXCEPTION 'ไม่สามารถปิด critical permissions ของ %: %', p_role_id, array_to_string(v_lost, ', ');
  END IF;

  -- 4. ห้าม role ที่ is_protected ปิด is_dangerous permissions ที่เคย granted
  IF v_role.is_protected THEN
    SELECT array_agg(rp.permission_key) INTO v_lost
    FROM public.role_permissions rp
    JOIN public.permissions p ON p.key = rp.permission_key
    WHERE rp.role_id = p_role_id
      AND rp.granted = true
      AND p.is_dangerous = true
      AND rp.permission_key <> ALL (p_perm_keys);
    IF v_lost IS NOT NULL AND array_length(v_lost, 1) > 0 THEN
      RAISE EXCEPTION 'Role % ถูก protect ห้ามปิด dangerous: %', p_role_id, array_to_string(v_lost, ', ');
    END IF;
  END IF;

  -- 5. apply: delete + reinsert (อะตอมิกใน transaction)
  DELETE FROM public.role_permissions WHERE role_id = p_role_id;
  INSERT INTO public.role_permissions (role_id, permission_key, granted, updated_by)
  SELECT p_role_id, k, true, auth.uid()
  FROM unnest(p_perm_keys) AS k
  WHERE EXISTS (SELECT 1 FROM public.permissions WHERE key = k);

  RETURN jsonb_build_object('role_id', p_role_id, 'granted_count', COALESCE(array_length(p_perm_keys, 1), 0));
END $$;

GRANT EXECUTE ON FUNCTION public.set_role_permissions(TEXT, TEXT[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
