-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Permissions v2: เพิ่ม permission keys ที่ขาด
--
-- ตรวจพบ feature ในระบบที่ไม่มี permission key ใน matrix (Phase 1 seed)
-- → ทำให้ admin คุมสิทธิ์ผ่านหน้า "ผู้ใช้และสิทธิ์" ไม่ได้ ต้องไปแก้โค้ดเอง
--
-- Feature ที่ขาด:
--   1. ตารางงาน (schedule)        — 4 keys
--   2. จัดชุดพนักงาน (uniform)     — 3 keys
--   3. ประกันสังคม (sso)          — 2 keys
--   4. ผู้บังคับบัญชาสาขา           — 1 key
--   5. ปฏิทินสาขา (leave calendar) — 1 key
--
-- รวม 11 permission keys ใหม่ + default role grants
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ═════════════ 1. INSERT permissions ใหม่ ═════════════
INSERT INTO public.permissions (key, scope, label_th, description, is_dangerous, is_critical, sort_order) VALUES
  -- ── SCHEDULE (ตารางงาน) ──
  ('schedule.view',              'leave', 'เห็นเมนู "ตารางงาน"',                 'พนักงานทุกคนเห็นของตัวเอง',         false, false, 620),
  ('schedule.manage',            'leave', 'จัด/แก้ตารางงาน (สาขาตัวเอง)',         'สำหรับ branch_manager',           false, false, 630),
  ('schedule.approve',           'leave', 'อนุมัติตารางงาน',                       'สำหรับ area_manager + OM',        false, false, 640),
  ('schedule.view_all_branches', 'leave', 'ดูตารางทุกสาขา',                       'scope modifier — สำหรับ HR/OM',   false, false, 650),
  -- ── LEAVE CALENDAR (ปฏิทินสาขา) ──
  ('leave_calendar.view',        'leave', 'เห็นเมนู "ปฏิทินสาขา"',                'safety: พนักงานทุกคนเห็น',          false, true,  660),
  -- ── UNIFORM (จัดชุดพนักงาน) ──
  ('uniform.view',               'employee', 'เห็นเมนู "จัดชุดพนักงาน"',           '',                                false, false, 250),
  ('uniform.manage',             'employee', 'จัดการ master ชุด + คำขอ',           '',                                false, false, 260),
  ('uniform.issue',              'employee', 'บันทึกการจัดส่งชุด',                 '',                                false, false, 270),
  -- ── SSO (ประกันสังคม) ──
  ('sso.view',                   'employee', 'เห็นเมนู "ประกันสังคม"',             '',                                false, false, 280),
  ('sso.manage',                 'employee', 'บันทึกแจ้งเข้า/ออก ปกส.',            '',                                false, false, 290),
  -- ── BRANCH MANAGERS (ผู้บังคับบัญชาสาขา) ──
  ('branch.assign_managers',     'system',   'ตั้งผู้บังคับบัญชาสาขา',              '',                                false, false, 725)
ON CONFLICT (key) DO UPDATE SET
  scope        = EXCLUDED.scope,
  label_th     = EXCLUDED.label_th,
  description  = EXCLUDED.description,
  is_dangerous = EXCLUDED.is_dangerous,
  is_critical  = EXCLUDED.is_critical,
  sort_order   = EXCLUDED.sort_order;

-- ═════════════ 2. SEED default role_permissions ═════════════
WITH grants (role_id, permission_key) AS (VALUES
  -- ── ADMIN ทำได้ทุกอย่าง ──
  ('admin', 'schedule.view'), ('admin', 'schedule.manage'),
  ('admin', 'schedule.approve'), ('admin', 'schedule.view_all_branches'),
  ('admin', 'leave_calendar.view'),
  ('admin', 'uniform.view'), ('admin', 'uniform.manage'), ('admin', 'uniform.issue'),
  ('admin', 'sso.view'), ('admin', 'sso.manage'),
  ('admin', 'branch.assign_managers'),
  -- ── HR เท่า admin (operation tasks) ──
  ('hr', 'schedule.view'), ('hr', 'schedule.manage'),
  ('hr', 'schedule.approve'), ('hr', 'schedule.view_all_branches'),
  ('hr', 'leave_calendar.view'),
  ('hr', 'uniform.view'), ('hr', 'uniform.manage'), ('hr', 'uniform.issue'),
  ('hr', 'sso.view'), ('hr', 'sso.manage'),
  ('hr', 'branch.assign_managers'),
  -- ── OPERATION MANAGER ──
  ('operation_manager', 'schedule.view'),
  ('operation_manager', 'schedule.approve'),
  ('operation_manager', 'schedule.view_all_branches'),
  ('operation_manager', 'leave_calendar.view'),
  -- ── AREA MANAGER ──
  ('area_manager', 'schedule.view'),
  ('area_manager', 'schedule.approve'),
  ('area_manager', 'leave_calendar.view'),
  -- ── BRANCH MANAGER (สาขาตัวเอง) ──
  ('branch_manager', 'schedule.view'),
  ('branch_manager', 'schedule.manage'),
  ('branch_manager', 'leave_calendar.view'),
  -- ── BRANCH STAFF (เห็นของตัวเอง) ──
  ('branch_staff', 'schedule.view'),
  ('branch_staff', 'leave_calendar.view'),
  -- ── VIEWER (อ่านอย่างเดียว) ──
  ('viewer', 'schedule.view'),
  ('viewer', 'leave_calendar.view')
)
INSERT INTO public.role_permissions (role_id, permission_key, granted)
SELECT g.role_id, g.permission_key, true
FROM grants g
WHERE EXISTS (SELECT 1 FROM public.roles       r WHERE r.id  = g.role_id)
  AND EXISTS (SELECT 1 FROM public.permissions p WHERE p.key = g.permission_key)
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- ═════════════ 3. RPC: register_permission — สำหรับ auto-detect ใน UI ═════════════
-- เมื่อ frontend diagnostic เจอ permission key ใน code ที่ไม่อยู่ใน DB matrix
-- → admin กดปุ่ม "Register" → เรียก RPC นี้เพื่อเพิ่มเข้า DB
-- default: ให้สิทธิ์ admin เท่านั้น (ปลอดภัย — admin คุมต่อใน matrix UI)
CREATE OR REPLACE FUNCTION public.register_permission(
  p_key          TEXT,
  p_scope        TEXT DEFAULT 'system',
  p_label_th     TEXT DEFAULT NULL,
  p_description  TEXT DEFAULT '',
  p_is_dangerous BOOLEAN DEFAULT false,
  p_sort_order   INT     DEFAULT 9000
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_label TEXT;
BEGIN
  -- เฉพาะ admin (มี permission.edit_matrix) ทำได้
  IF NOT public.user_has_permission('permission.edit_matrix') THEN
    RAISE EXCEPTION 'ต้องเป็น admin (permission.edit_matrix) เท่านั้น';
  END IF;
  -- validate
  IF p_key IS NULL OR p_key !~ '^[a-z_]+\.[a-z_]+$' THEN
    RAISE EXCEPTION 'key ไม่ถูกรูปแบบ — ต้องเป็น "group.action" (a-z, _)';
  END IF;
  IF p_scope NOT IN ('employee', 'payroll', 'leave', 'system') THEN
    RAISE EXCEPTION 'scope ต้องเป็นหนึ่งใน: employee, payroll, leave, system';
  END IF;
  v_label := COALESCE(NULLIF(trim(p_label_th), ''), p_key);

  -- INSERT permission (ถ้ามีแล้ว → no-op)
  INSERT INTO public.permissions (key, scope, label_th, description, is_dangerous, is_critical, sort_order)
  VALUES (p_key, p_scope, v_label, p_description, p_is_dangerous, false, p_sort_order)
  ON CONFLICT (key) DO NOTHING;

  -- ให้สิทธิ์ admin โดย default (ปลอดภัย)
  INSERT INTO public.role_permissions (role_id, permission_key, granted)
  VALUES ('admin', p_key, true)
  ON CONFLICT (role_id, permission_key) DO NOTHING;

  RETURN jsonb_build_object(
    'registered', true,
    'key', p_key,
    'label', v_label,
    'scope', p_scope,
    'message', 'ลงทะเบียน permission แล้ว — ตั้ง admin = ได้ (เปิดให้ role อื่นใน matrix)'
  );
END $$;

GRANT EXECUTE ON FUNCTION public.register_permission(TEXT, TEXT, TEXT, TEXT, BOOLEAN, INT) TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
DECLARE
  v_total INT;
BEGIN
  SELECT COUNT(*) INTO v_total FROM public.permissions;
  RAISE NOTICE '✅ Permissions v2 รัน เสร็จแล้ว';
  RAISE NOTICE '   - เพิ่ม 11 permission keys (schedule/uniform/sso/branch.assign/leave_cal)';
  RAISE NOTICE '   - รวมตอนนี้: % permission keys', v_total;
  RAISE NOTICE '   - RPC register_permission() พร้อมใช้ — admin เพิ่ม key ใหม่จาก UI ได้';
END $$;
