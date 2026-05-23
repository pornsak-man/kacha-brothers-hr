-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Security fix C5: Extend self-role trigger
-- ปัญหา: C1 trigger เดิม block แค่ self-update (OLD.user_id = auth.uid())
--        → HR ใช้ policy write_hr UPDATE row ของคนอื่นแล้วตั้ง role=admin ได้
-- แก้:   ถ้า caller ไม่ใช่ admin → revert role/employee_id/managed_branches
--        ของ row ใดๆ ก็ตาม (ไม่ใช่แค่ของตัวเอง)
--        + RAISE EXCEPTION ให้ audit log จับเห็น
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.guard_user_profiles_self_update()
RETURNS TRIGGER LANGUAGE PLPGSQL SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_is_admin BOOLEAN;
  v_changed_role BOOLEAN;
  v_changed_emp BOOLEAN;
  v_changed_branches BOOLEAN;
BEGIN
  -- service_role bypass (สำหรับ admin RPC ที่ run ใน service context)
  IF current_setting('request.jwt.claim.role', true) = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- ตรวจว่า caller เป็น admin
  SELECT (role = 'admin') INTO v_is_admin
  FROM public.user_profiles
  WHERE user_id = auth.uid();

  -- admin → ปล่อยผ่าน (จัดการได้ทุกอย่าง)
  IF COALESCE(v_is_admin, false) THEN
    RETURN NEW;
  END IF;

  -- non-admin (HR, manager, staff) — ห้ามแก้ sensitive fields ของใครก็ตาม
  -- C5 fix: ครอบคลุมทั้ง self-update และ update คนอื่น
  v_changed_role     := (NEW.role IS DISTINCT FROM OLD.role);
  v_changed_emp      := (NEW.employee_id IS DISTINCT FROM OLD.employee_id);
  v_changed_branches := (NEW.managed_branches IS DISTINCT FROM OLD.managed_branches);

  IF v_changed_role OR v_changed_emp OR v_changed_branches THEN
    -- RAISE EXCEPTION เพื่อให้ audit log จับ + client เห็น error
    -- (เดิม revert เงียบ — admin ตรวจไม่เจอว่ามีความพยายาม escalate)
    RAISE EXCEPTION 'ไม่มีสิทธิ์แก้ role/employee_id/managed_branches — admin เท่านั้นที่ทำได้ (set_employee_role RPC)';
  END IF;

  RETURN NEW;
END $$;

-- Trigger คงเดิม (ใช้ฟังก์ชันเดิมที่เพิ่ง replaced)
DROP TRIGGER IF EXISTS trg_user_profiles_self_guard ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_self_guard
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_user_profiles_self_update();

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ C5 fix: trigger ขยายขอบเขตป้องกัน — ห้าม non-admin แก้ role ของใครๆ';
  RAISE NOTICE '   เปลี่ยนเป็น RAISE EXCEPTION → client เห็น error + audit log จับ';
  RAISE NOTICE '   admin ยังใช้ set_employee_role() RPC ได้ตามปกติ';
END $$;

-- ═══════════════════════════════════════════════════════════
-- ทดสอบหลังรัน:
--   1) HR login → console:
--      DB.client.from('user_profiles').update({role:'admin'}).eq('user_id', '<any_uid>')
--      → ควรได้ error: "ไม่มีสิทธิ์แก้ role/employee_id/managed_branches..."
--   2) HR ใช้ปุ่ม "ตั้ง Role" ในหน้า user-roles → call set_employee_role()
--      → ยังใช้งานปกติ (RPC bypass trigger ผ่าน service_role)
--   3) Admin update โปรไฟล์ใครก็ได้ → ผ่าน
-- ═══════════════════════════════════════════════════════════
