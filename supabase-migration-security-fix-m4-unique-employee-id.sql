-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Security Fix M4: UNIQUE user_profiles.employee_id
--
-- ปัญหาเดิม (schema.sql line 187):
--   - user_profiles.employee_id ไม่มี UNIQUE constraint
--   - 2 user record สามารถมี employee_id เดียวกันได้
--   - ผลกระทบ:
--     * current_user_employee_id() helper อาจคืน row ผิด (random/limit 1)
--     * RLS scope filter (เช่น can_view_employee() ใน C4) เช็คผ่าน employee_id
--       → ถ้ามี collision → user คนหนึ่งเห็นข้อมูลของคนอื่น
--     * impersonate audit (H6) record_id ผิด
--
-- การแก้:
--   1. เช็คก่อนว่ามี duplicate ไหม → ถ้ามี ให้ warn (ไม่ลบให้อัตโนมัติ)
--   2. เพิ่ม partial unique index (UNIQUE ... WHERE employee_id IS NOT NULL)
--      เพื่อรองรับ profile ที่ยังไม่ผูก employee (admin บัญชีพิเศษ)
--
-- ⚠️ ถ้ามี duplicate อยู่ migration จะ FAIL ที่ขั้น CREATE UNIQUE INDEX
--    → ดู NOTICE ก่อน, แก้ duplicate ใน admin console, แล้วรันใหม่
--
-- รันใน Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════

-- 1. ตรวจหา duplicate ก่อน
DO $$
DECLARE
  v_dup RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR v_dup IN
    SELECT employee_id, COUNT(*) AS cnt, array_agg(user_id ORDER BY created_at) AS user_ids
    FROM public.user_profiles
    WHERE employee_id IS NOT NULL
    GROUP BY employee_id
    HAVING COUNT(*) > 1
  LOOP
    v_count := v_count + 1;
    RAISE WARNING '🔴 Duplicate: employee_id=% มี user_id ผูกอยู่ % คน → %',
      v_dup.employee_id, v_dup.cnt, v_dup.user_ids;
  END LOOP;
  IF v_count = 0 THEN
    RAISE NOTICE '✅ ไม่มี duplicate employee_id ใน user_profiles — ปลอดภัยที่จะใส่ UNIQUE';
  ELSE
    RAISE WARNING '⚠️  พบ % employee_id ที่ duplicate — ต้องแก้ก่อนสร้าง UNIQUE INDEX', v_count;
    RAISE WARNING '   ตัวอย่างคำสั่งแก้ใน Supabase SQL Editor:';
    RAISE WARNING '   DELETE FROM public.user_profiles WHERE user_id IN (... duplicate ที่ไม่ใช้ ...);';
    RAISE WARNING '   หรือ UPDATE ... SET employee_id = NULL WHERE user_id = ...;';
  END IF;
END $$;

-- 2. เพิ่ม UNIQUE constraint (partial — เว้น NULL ให้ใส่ได้หลายคน)
-- ใช้ DO block เพื่อ idempotent — ถ้า index มีแล้วก็ skip
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'user_profiles'
      AND indexname = 'uq_user_profiles_employee_id'
  ) THEN
    BEGIN
      CREATE UNIQUE INDEX uq_user_profiles_employee_id
        ON public.user_profiles (employee_id)
        WHERE employee_id IS NOT NULL;
      RAISE NOTICE '✅ สร้าง UNIQUE INDEX uq_user_profiles_employee_id สำเร็จ';
    EXCEPTION WHEN unique_violation THEN
      RAISE WARNING '❌ สร้าง UNIQUE INDEX ไม่สำเร็จ — มี duplicate employee_id ค้างอยู่ (ดู WARNING ก่อนหน้า)';
      RAISE WARNING '   migration ส่วนนี้ skip แล้ว — แก้ duplicate ก่อนรันใหม่';
    END;
  ELSE
    RAISE NOTICE 'ℹ️  uq_user_profiles_employee_id มีอยู่แล้ว — skip';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Security Fix M4 รัน เสร็จแล้ว';
  RAISE NOTICE '   - UNIQUE INDEX ปกป้อง user_profiles.employee_id ไม่ให้ collide';
  RAISE NOTICE '   - employee_id = NULL ใส่ได้หลาย row (admin บัญชีพิเศษไม่ผูก employee)';
END $$;
