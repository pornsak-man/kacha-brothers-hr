-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Migration: Permission Matrix v1 (PHASE 1)
-- ระบบ RBAC แบบ dynamic — admin จัดการสิทธิ์ของแต่ละ role ผ่าน UI ได้
--
-- ตารางใหม่ 3 ตัว: roles, permissions, role_permissions
-- + RPC: user_permissions_list(), user_has_permission(key), set_role_permissions(...)
-- + audit trigger บน role_permissions
--
-- ⚠️ Phase นี้ "ไม่กระทบ permission จริง" — โค้ดเดิมยังใช้ isHR/isAdmin
--    Phase 2 จะเพิ่ม DB.hasPermission() helper แบบ fallback
--    Phase 3-5 ค่อย refactor call sites + RLS
--
-- รันใน Supabase SQL Editor ครั้งเดียว (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

-- ═════════════ 1. SCHEMA ═════════════

-- ── 1.1 roles — ทะเบียน role ทั้งหมด (เริ่ม 7 ตัวที่ hardcode อยู่) ──
CREATE TABLE IF NOT EXISTS public.roles (
  id            TEXT PRIMARY KEY,        -- 'admin', 'hr', custom keys (snake_case)
  label_th      TEXT NOT NULL,
  badge_class   TEXT DEFAULT '',         -- 'badge-primary', 'badge-success', etc.
  description   TEXT DEFAULT '',
  is_system     BOOLEAN NOT NULL DEFAULT false,  -- true = ลบไม่ได้ (7 roles เดิม)
  is_protected  BOOLEAN NOT NULL DEFAULT false,  -- true = ลด permission อันตรายไม่ได้ (admin)
  sort_order    INTEGER NOT NULL DEFAULT 100,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_roles_sort ON public.roles(sort_order);

-- ── 1.2 permissions — catalog สิทธิ์ทั้งหมด ──
CREATE TABLE IF NOT EXISTS public.permissions (
  key           TEXT PRIMARY KEY,        -- 'employee.view_salary'
  scope         TEXT NOT NULL,           -- 'employee'|'payroll'|'leave'|'system'
  label_th      TEXT NOT NULL,
  description   TEXT DEFAULT '',
  is_dangerous  BOOLEAN NOT NULL DEFAULT false,  -- เปิด/ปิดต้องระวัง (recommend confirm 2 ชั้น)
  is_critical   BOOLEAN NOT NULL DEFAULT false,  -- ห้ามทุก role ปิด (safety lock)
  sort_order    INTEGER NOT NULL DEFAULT 100,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_permissions_scope ON public.permissions(scope, sort_order);

-- ── 1.3 role_permissions — mapping role × permission ──
CREATE TABLE IF NOT EXISTS public.role_permissions (
  role_id        TEXT NOT NULL REFERENCES public.roles(id)        ON DELETE CASCADE,
  permission_key TEXT NOT NULL REFERENCES public.permissions(key) ON DELETE CASCADE,
  granted        BOOLEAN NOT NULL DEFAULT true,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by     UUID,
  PRIMARY KEY (role_id, permission_key)
);
CREATE INDEX IF NOT EXISTS idx_role_perms_role ON public.role_permissions(role_id) WHERE granted = true;

-- ── 1.4 auto-update updated_at สำหรับ roles ──
CREATE OR REPLACE FUNCTION public.roles_set_updated_at()
RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS on_roles_updated ON public.roles;
CREATE TRIGGER on_roles_updated BEFORE UPDATE ON public.roles
  FOR EACH ROW EXECUTE FUNCTION public.roles_set_updated_at();

-- ── 1.5 audit trigger สำหรับ role_permissions ──
CREATE OR REPLACE FUNCTION public.role_perms_audit()
RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.audit_log (actor_id, action, table_name, row_id, payload)
  VALUES (
    auth.uid(),
    TG_OP,
    'role_permissions',
    COALESCE(NEW.role_id, OLD.role_id) || ':' || COALESCE(NEW.permission_key, OLD.permission_key),
    jsonb_build_object(
      'old', CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
      'new', CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
    )
  );
  RETURN COALESCE(NEW, OLD);
EXCEPTION WHEN OTHERS THEN
  -- ถ้าตาราง audit_log ยังไม่มี ก็ไม่ block การแก้ matrix
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS on_role_perms_audit ON public.role_permissions;
CREATE TRIGGER on_role_perms_audit AFTER INSERT OR UPDATE OR DELETE ON public.role_permissions
  FOR EACH ROW EXECUTE FUNCTION public.role_perms_audit();

-- ═════════════ 2. RLS ═════════════

ALTER TABLE public.roles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permissions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

-- ทุก authenticated user อ่านได้ (จำเป็นเพราะ hasPermission() ต้อง query)
DROP POLICY IF EXISTS "read_authenticated" ON public.roles;
DROP POLICY IF EXISTS "read_authenticated" ON public.permissions;
DROP POLICY IF EXISTS "read_authenticated" ON public.role_permissions;
CREATE POLICY "read_authenticated" ON public.roles            FOR SELECT TO authenticated USING (true);
CREATE POLICY "read_authenticated" ON public.permissions      FOR SELECT TO authenticated USING (true);
CREATE POLICY "read_authenticated" ON public.role_permissions FOR SELECT TO authenticated USING (true);

-- เขียน — admin only (Phase 4 จะมี UI ให้ admin แก้ผ่าน RPC)
DROP POLICY IF EXISTS "write_admin" ON public.roles;
DROP POLICY IF EXISTS "write_admin" ON public.permissions;
DROP POLICY IF EXISTS "write_admin" ON public.role_permissions;
CREATE POLICY "write_admin" ON public.roles            FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY "write_admin" ON public.permissions      FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY "write_admin" ON public.role_permissions FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Realtime — ให้ multi-device sync ทันทีเมื่อ admin แก้สิทธิ์
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['roles', 'permissions', 'role_permissions'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;

-- ═════════════ 3. SEED — 7 ROLES ═════════════

INSERT INTO public.roles (id, label_th, badge_class, description, is_system, is_protected, sort_order) VALUES
  ('admin',             'Admin',             'badge-primary', 'ผู้ดูแลระบบ — ทำได้ทุกอย่าง',                       true, true,  10),
  ('hr',                'HR',                'badge-success', 'ฝ่ายบุคคล — จัดการพนักงาน + เงินเดือน',              true, false, 20),
  ('operation_manager', 'Operation Manager', 'badge-info',    'ผู้จัดการฝ่ายปฏิบัติการ — เห็นทุกสาขา',               true, false, 30),
  ('area_manager',      'Area Manager',      'badge-info',    'ผู้จัดการเขต — เห็นเฉพาะสาขาที่ดูแล',                 true, false, 40),
  ('branch_manager',    'ผู้จัดการสาขา',     'badge-warning', 'ผู้จัดการสาขา — เห็นเฉพาะสาขาตัวเอง',                true, false, 50),
  ('branch_staff',      'พนักงานสาขา',       '',              'พนักงานสาขา — เห็นเฉพาะตัวเอง (default)',          true, false, 60),
  ('viewer',            'ผู้ใช้ทั่วไป',        '',              'ผู้ใช้ทั่วไป — เห็นเฉพาะตัวเอง (fallback role)',     true, false, 70)
ON CONFLICT (id) DO UPDATE SET
  label_th     = EXCLUDED.label_th,
  badge_class  = EXCLUDED.badge_class,
  description  = EXCLUDED.description,
  is_system    = EXCLUDED.is_system,
  is_protected = EXCLUDED.is_protected,
  sort_order   = EXCLUDED.sort_order;

-- ═════════════ 4. SEED — 62 PERMISSIONS ═════════════
-- จัดกลุ่ม 4 scope ตาม Phase 1 plan
-- is_critical = true → safety lock (ทุก role ห้ามปิด เพื่อกัน lock-out)
-- is_dangerous = true → UI ต้อง confirm 2 ชั้นก่อนเปิดให้ role ที่ไม่ใช่ admin

-- ── 4.1 EMPLOYEE (14) ──
INSERT INTO public.permissions (key, scope, label_th, description, is_dangerous, is_critical, sort_order) VALUES
  ('employee.view_list',          'employee', 'เห็นเมนูทะเบียนพนักงาน',           '',                                                     false, false, 110),
  ('employee.view_own_branch',    'employee', 'เห็นพนักงานในสาขาตัวเอง',          'scope modifier — ใช้คู่กับ view_list',                     false, false, 120),
  ('employee.view_all_branches',  'employee', 'เห็นพนักงานทุกสาขา',               'scope modifier — ข้าม branch filter',                      false, false, 130),
  ('employee.view_pii',           'employee', 'เห็นข้อมูลส่วนบุคคล (ปชช./บัญชี)',   'รวม nat_id, passport, bank_acc, sso_no',              true,  false, 140),
  ('employee.view_salary',        'employee', 'เห็นเงินเดือน + allowance',         '',                                                     true,  false, 150),
  ('employee.create',             'employee', 'เพิ่มพนักงานใหม่',                  '',                                                     false, false, 160),
  ('employee.edit',               'employee', 'แก้ไขข้อมูลพนักงาน',                '',                                                     false, false, 170),
  ('employee.delete',             'employee', 'ลบพนักงาน',                       'soft delete + ลบ user account',                          true,  false, 180),
  ('employee.terminate',          'employee', 'บันทึกพ้นสภาพ',                    '',                                                     false, false, 190),
  ('employee.bulk_import',        'employee', 'นำเข้าพนักงานจาก Excel',           '',                                                     false, false, 200),
  ('employee.export_xlsx',        'employee', 'ส่งออกทะเบียนเป็น Excel',          '',                                                     false, false, 210),
  ('applicant.view',              'employee', 'เห็นเมนู "รับสมัคร" + ดูผู้สมัคร',     '',                                                     false, false, 220),
  ('applicant.manage',            'employee', 'เพิ่ม/แก้/ลบ ผู้สมัคร + รับเข้า',     '',                                                     false, false, 230),
  ('blacklist.manage',            'employee', 'จัดการรายชื่อห้ามจ้าง',             '',                                                     true,  false, 240)
ON CONFLICT (key) DO UPDATE SET label_th = EXCLUDED.label_th, description = EXCLUDED.description, sort_order = EXCLUDED.sort_order;

-- ── 4.2 PAYROLL (13) ──
INSERT INTO public.permissions (key, scope, label_th, description, is_dangerous, is_critical, sort_order) VALUES
  ('payroll.view_menu',           'payroll', 'เห็นกลุ่มเมนู "การเงิน"',            '',                                                     false, false, 310),
  ('salary.adjust',               'payroll', 'บันทึกการปรับเงินเดือน',            'รวม ปรับตำแหน่ง/สาขา/ฝ่าย',                                false, false, 320),
  ('salary.import',               'payroll', 'นำเข้าการปรับจาก Excel',            '',                                                     false, false, 330),
  ('salary.view_history',         'payroll', 'ดูประวัติการปรับเงินเดือน',           '',                                                     true,  false, 340),
  ('loan.view',                   'payroll', 'ดูรายการกู้',                       '',                                                     false, false, 350),
  ('loan.manage',                 'payroll', 'เพิ่ม/แก้/ลบ การกู้',                '',                                                     false, false, 360),
  ('advance.view',                'payroll', 'ดูเบิกล่วงหน้า',                    '',                                                     false, false, 370),
  ('advance.manage',              'payroll', 'เพิ่ม/แก้/ลบ เบิกล่วงหน้า',          '',                                                     false, false, 380),
  ('allowance.view',              'payroll', 'ดูเบี้ยเลี้ยงรายเดือน',              '',                                                     false, false, 390),
  ('allowance.manage',            'payroll', 'เพิ่ม/แก้/ลบ เบี้ยเลี้ยง',            '',                                                     false, false, 400),
  ('evaluation.view',             'payroll', 'ดูประเมินผลงาน',                    '',                                                     false, false, 410),
  ('evaluation.manage',           'payroll', 'เพิ่ม/แก้/ลบ ประเมิน',              '',                                                     false, false, 420),
  ('report.export_payroll',       'payroll', 'ส่งออก payroll/loans XLSX',         '',                                                     false, false, 430)
ON CONFLICT (key) DO UPDATE SET label_th = EXCLUDED.label_th, description = EXCLUDED.description, sort_order = EXCLUDED.sort_order;

-- ── 4.3 LEAVE / SHIFT / CALENDAR (11) ──
INSERT INTO public.permissions (key, scope, label_th, description, is_dangerous, is_critical, sort_order) VALUES
  ('leave.request_own',           'leave', 'ส่งคำขอลาของตัวเอง',                'safety: ห้ามปิด',                                          false, true,  510),
  ('leave.request_for_others',    'leave', 'ส่งคำขอลาแทนคนอื่น',                '',                                                     false, false, 520),
  ('leave.approve_own_branch',    'leave', 'อนุมัติคำขอในสาขาที่ดูแล',            '',                                                     false, false, 530),
  ('leave.approve_all',           'leave', 'อนุมัติคำขอใดก็ได้ (override)',       '',                                                     true,  false, 540),
  ('leave.delete',                'leave', 'ลบคำขอลา (รวม approved)',          '',                                                     true,  false, 550),
  ('leave.bypass_backdate',       'leave', 'อนุมัติย้อนหลังได้',                  '',                                                     false, false, 560),
  ('leave.manage_types',          'leave', 'จัดการประเภทการลา (master)',        '',                                                     true,  false, 570),
  ('holiday.manage',              'leave', 'จัดการปฏิทินวันหยุด',                '',                                                     false, false, 580),
  ('holiday_swap.request_own',    'leave', 'ขอเปลี่ยนวันหยุดของตัวเอง',           '',                                                     false, false, 590),
  ('holiday_swap.request_for_others', 'leave', 'บันทึก swap ให้พนักงาน',          '',                                                     false, false, 600),
  ('holiday_swap.auto_approve',   'leave', 'อนุมัติ swap ทันทีตอนสร้าง',          '',                                                     false, false, 610)
ON CONFLICT (key) DO UPDATE SET label_th = EXCLUDED.label_th, description = EXCLUDED.description, sort_order = EXCLUDED.sort_order;

-- ── 4.4 SYSTEM (17) ──
INSERT INTO public.permissions (key, scope, label_th, description, is_dangerous, is_critical, sort_order) VALUES
  ('branch.view',                 'system', 'เห็นเมนู "สาขา"',                    '',                                                     false, false, 710),
  ('branch.manage',               'system', 'เพิ่ม/แก้/ลบ สาขา',                  '',                                                     false, false, 720),
  ('department.view',             'system', 'เห็นเมนู "ฝ่าย"',                    '',                                                     false, false, 730),
  ('department.manage',           'system', 'เพิ่ม/แก้/ลบ ฝ่าย',                  '',                                                     false, false, 740),
  ('position.view',               'system', 'เห็นเมนู "ระดับตำแหน่ง"',             '',                                                     false, false, 750),
  ('position.manage',             'system', 'เพิ่ม/แก้/ลบ ตำแหน่ง + scope',       '',                                                     false, false, 760),
  ('user.view_accounts',          'system', 'เห็นหน้า "ผู้ใช้และสิทธิ์"',            'safety: admin ต้องเข้าได้เสมอ',                          false, true,  770),
  ('user.create_account',         'system', 'สร้าง email/password ให้พนักงาน',    '',                                                     false, false, 780),
  ('user.bulk_create',            'system', 'bulk create บัญชี',                  '',                                                     false, false, 790),
  ('user.reset_password',         'system', 'รีเซ็ตรหัสผ่านพนักงาน',              '',                                                     false, false, 800),
  ('user.set_role',               'system', 'เปลี่ยน role ของพนักงาน',           'ห้าม set admin (ดู user.set_role_admin)',                false, false, 810),
  ('user.set_role_admin',         'system', 'ตั้งพนักงานเป็น Admin',              'อันตรายสูง — admin ปลดไม่ได้',                              true,  false, 820),
  ('system.edit_company',         'system', 'แก้ company settings',              '',                                                     false, false, 830),
  ('system.view_audit',           'system', 'ดู audit log + swap history',        '',                                                     false, false, 840),
  ('system.full_backup',          'system', 'export JSON ทั้งระบบ',              'อันตรายสูง — admin ปลดไม่ได้',                              true,  false, 850),
  ('announcement.manage',         'system', 'สร้าง/แก้/ลบ ประกาศ',               '',                                                     false, false, 860),
  ('permission.edit_matrix',      'system', 'แก้ permission matrix (meta!)',     'อันตรายสูง — admin ปลดไม่ได้',                              true,  true,  870)
ON CONFLICT (key) DO UPDATE SET label_th = EXCLUDED.label_th, description = EXCLUDED.description, sort_order = EXCLUDED.sort_order;

-- ═════════════ 5. SEED — DEFAULT ROLE × PERMISSION MATRIX ═════════════
-- ต้องตรงกับพฤติกรรมปัจจุบันที่ hardcode อยู่ (isHR/isAdmin/role check)
-- กฎ: ใช้ INSERT...ON CONFLICT DO NOTHING — ครั้งแรก seed, รันซ้ำไม่ทับ user customization

-- helper macro: grant(role, perm_key)
-- ใช้ CTE จะอ่านง่ายและ idempotent ปลอดภัย

WITH grants (role_id, permission_key) AS (VALUES
  -- ════ ADMIN — ทุก permission (62 keys) ════
  ('admin', 'employee.view_list'),
  ('admin', 'employee.view_all_branches'),
  ('admin', 'employee.view_pii'),
  ('admin', 'employee.view_salary'),
  ('admin', 'employee.create'),
  ('admin', 'employee.edit'),
  ('admin', 'employee.delete'),
  ('admin', 'employee.terminate'),
  ('admin', 'employee.bulk_import'),
  ('admin', 'employee.export_xlsx'),
  ('admin', 'applicant.view'),
  ('admin', 'applicant.manage'),
  ('admin', 'blacklist.manage'),
  ('admin', 'payroll.view_menu'),
  ('admin', 'salary.adjust'),
  ('admin', 'salary.import'),
  ('admin', 'salary.view_history'),
  ('admin', 'loan.view'),
  ('admin', 'loan.manage'),
  ('admin', 'advance.view'),
  ('admin', 'advance.manage'),
  ('admin', 'allowance.view'),
  ('admin', 'allowance.manage'),
  ('admin', 'evaluation.view'),
  ('admin', 'evaluation.manage'),
  ('admin', 'report.export_payroll'),
  ('admin', 'leave.request_own'),
  ('admin', 'leave.request_for_others'),
  ('admin', 'leave.approve_own_branch'),
  ('admin', 'leave.approve_all'),
  ('admin', 'leave.delete'),
  ('admin', 'leave.bypass_backdate'),
  ('admin', 'leave.manage_types'),
  ('admin', 'holiday.manage'),
  ('admin', 'holiday_swap.request_own'),
  ('admin', 'holiday_swap.request_for_others'),
  ('admin', 'holiday_swap.auto_approve'),
  ('admin', 'branch.view'),
  ('admin', 'branch.manage'),
  ('admin', 'department.view'),
  ('admin', 'department.manage'),
  ('admin', 'position.view'),
  ('admin', 'position.manage'),
  ('admin', 'user.view_accounts'),
  ('admin', 'user.create_account'),
  ('admin', 'user.bulk_create'),
  ('admin', 'user.reset_password'),
  ('admin', 'user.set_role'),
  ('admin', 'user.set_role_admin'),
  ('admin', 'system.edit_company'),
  ('admin', 'system.view_audit'),
  ('admin', 'system.full_backup'),
  ('admin', 'announcement.manage'),
  ('admin', 'permission.edit_matrix'),

  -- ════ HR — เหมือน admin ยกเว้น: set_role_admin, edit_company, full_backup, edit_matrix, manage_types, view_audit ════
  ('hr', 'employee.view_list'),
  ('hr', 'employee.view_all_branches'),
  ('hr', 'employee.view_pii'),
  ('hr', 'employee.view_salary'),
  ('hr', 'employee.create'),
  ('hr', 'employee.edit'),
  ('hr', 'employee.delete'),
  ('hr', 'employee.terminate'),
  ('hr', 'employee.bulk_import'),
  ('hr', 'employee.export_xlsx'),
  ('hr', 'applicant.view'),
  ('hr', 'applicant.manage'),
  ('hr', 'blacklist.manage'),
  ('hr', 'payroll.view_menu'),
  ('hr', 'salary.adjust'),
  ('hr', 'salary.import'),
  ('hr', 'salary.view_history'),
  ('hr', 'loan.view'),
  ('hr', 'loan.manage'),
  ('hr', 'advance.view'),
  ('hr', 'advance.manage'),
  ('hr', 'allowance.view'),
  ('hr', 'allowance.manage'),
  ('hr', 'evaluation.view'),
  ('hr', 'evaluation.manage'),
  ('hr', 'report.export_payroll'),
  ('hr', 'leave.request_own'),
  ('hr', 'leave.request_for_others'),
  ('hr', 'leave.approve_own_branch'),
  ('hr', 'leave.approve_all'),
  ('hr', 'leave.delete'),
  ('hr', 'leave.bypass_backdate'),
  ('hr', 'holiday.manage'),
  ('hr', 'holiday_swap.request_own'),
  ('hr', 'holiday_swap.request_for_others'),
  ('hr', 'holiday_swap.auto_approve'),
  ('hr', 'branch.view'),
  ('hr', 'branch.manage'),
  ('hr', 'department.view'),
  ('hr', 'department.manage'),
  ('hr', 'position.view'),
  ('hr', 'position.manage'),
  ('hr', 'user.view_accounts'),
  ('hr', 'user.create_account'),
  ('hr', 'user.bulk_create'),
  ('hr', 'user.reset_password'),
  ('hr', 'user.set_role'),
  ('hr', 'announcement.manage'),

  -- ════ OPERATION MANAGER — เห็นทุกสาขา, อนุมัติลา, ดู master, ไม่มี write payroll ════
  ('operation_manager', 'employee.view_list'),
  ('operation_manager', 'employee.view_all_branches'),
  ('operation_manager', 'leave.request_own'),
  ('operation_manager', 'leave.request_for_others'),
  ('operation_manager', 'leave.approve_own_branch'),
  ('operation_manager', 'holiday_swap.request_own'),
  ('operation_manager', 'holiday_swap.request_for_others'),
  ('operation_manager', 'branch.view'),
  ('operation_manager', 'department.view'),
  ('operation_manager', 'position.view'),

  -- ════ AREA MANAGER — เห็นสาขาที่ดูแล (managed_branches), อนุมัติลา ════
  ('area_manager', 'employee.view_list'),
  ('area_manager', 'employee.view_own_branch'),
  ('area_manager', 'leave.request_own'),
  ('area_manager', 'leave.request_for_others'),
  ('area_manager', 'leave.approve_own_branch'),
  ('area_manager', 'holiday_swap.request_own'),
  ('area_manager', 'holiday_swap.request_for_others'),
  ('area_manager', 'branch.view'),
  ('area_manager', 'department.view'),
  ('area_manager', 'position.view'),

  -- ════ BRANCH MANAGER — สาขาตัวเอง + อนุมัติลา ════
  ('branch_manager', 'employee.view_list'),
  ('branch_manager', 'employee.view_own_branch'),
  ('branch_manager', 'leave.request_own'),
  ('branch_manager', 'leave.request_for_others'),
  ('branch_manager', 'leave.approve_own_branch'),
  ('branch_manager', 'holiday_swap.request_own'),
  ('branch_manager', 'holiday_swap.request_for_others'),
  ('branch_manager', 'branch.view'),
  ('branch_manager', 'department.view'),
  ('branch_manager', 'position.view'),

  -- ════ BRANCH STAFF — ตัวเองเท่านั้น ════
  ('branch_staff', 'leave.request_own'),
  ('branch_staff', 'holiday_swap.request_own'),

  -- ════ VIEWER — minimal (fallback) ════
  ('viewer', 'leave.request_own'),
  ('viewer', 'holiday_swap.request_own')
)
INSERT INTO public.role_permissions (role_id, permission_key, granted)
SELECT g.role_id, g.permission_key, true
FROM grants g
WHERE EXISTS (SELECT 1 FROM public.roles       r WHERE r.id  = g.role_id)
  AND EXISTS (SELECT 1 FROM public.permissions p WHERE p.key = g.permission_key)
ON CONFLICT (role_id, permission_key) DO NOTHING;

-- ═════════════ 6. RPC FUNCTIONS ═════════════

-- ── 6.1 user_permissions_list() — ดึง permission keys ของ user ปัจจุบัน ──
-- ใช้ใน client เพื่อ cache เข้า DB.hasPermission()
CREATE OR REPLACE FUNCTION public.user_permissions_list()
RETURNS TABLE (permission_key TEXT)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT rp.permission_key
  FROM public.user_profiles up
  JOIN public.role_permissions rp ON rp.role_id = up.role
  WHERE up.user_id = auth.uid() AND rp.granted = true;
$$;
GRANT EXECUTE ON FUNCTION public.user_permissions_list() TO authenticated;

-- ── 6.2 user_has_permission(key) — เช็คทีละ key (ใช้ใน RLS policy ภายหลัง) ──
CREATE OR REPLACE FUNCTION public.user_has_permission(p_key TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_profiles up
    JOIN public.role_permissions rp ON rp.role_id = up.role
    WHERE up.user_id = auth.uid()
      AND rp.permission_key = p_key
      AND rp.granted = true
  );
$$;
GRANT EXECUTE ON FUNCTION public.user_has_permission(TEXT) TO authenticated;

-- ── 6.3 set_role_permissions(role_id, grants[]) — bulk update matrix (Phase 4) ──
-- รับ array ของ permission keys ที่ should be granted
-- granted=true สำหรับ key ที่อยู่ใน array, granted=false (หรือ delete) สำหรับที่เหลือ
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
  v_caller_role TEXT;
  v_role        public.roles%ROWTYPE;
  v_critical_count INTEGER;
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

  -- 3. ห้ามปิด critical permissions (safety lock)
  SELECT COUNT(*) INTO v_critical_count
  FROM public.permissions
  WHERE is_critical = true
    AND key NOT IN (SELECT unnest(p_perm_keys));
  IF v_critical_count > 0 THEN
    RAISE EXCEPTION 'ไม่สามารถปิด critical permissions ได้ (safety lock)';
  END IF;

  -- 4. ห้าม role ที่ is_protected ปิด is_dangerous permissions (admin lock)
  IF v_role.is_protected THEN
    PERFORM 1 FROM public.permissions
    WHERE is_dangerous = true AND key NOT IN (SELECT unnest(p_perm_keys));
    IF FOUND THEN
      RAISE EXCEPTION 'Role % ถูก protect ห้ามปิด dangerous permissions', p_role_id;
    END IF;
  END IF;

  -- 5. apply: delete + reinsert (อะตอมิกใน transaction)
  DELETE FROM public.role_permissions WHERE role_id = p_role_id;
  INSERT INTO public.role_permissions (role_id, permission_key, granted, updated_by)
  SELECT p_role_id, k, true, auth.uid()
  FROM unnest(p_perm_keys) AS k
  WHERE EXISTS (SELECT 1 FROM public.permissions WHERE key = k);

  RETURN jsonb_build_object('role_id', p_role_id, 'granted_count', array_length(p_perm_keys, 1));
END $$;
GRANT EXECUTE ON FUNCTION public.set_role_permissions(TEXT, TEXT[]) TO authenticated;

NOTIFY pgrst, 'reload schema';
-- ═══════════════════════════════════════════════════════════
-- PHASE 1 เสร็จสิ้น
-- ขั้นต่อไป: Phase 2 = เพิ่ม DB.hasPermission() helper ใน js/data.js
-- ═══════════════════════════════════════════════════════════
