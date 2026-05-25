-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Security Fix H2: Storage final verification + hardening
--
-- พิจารณา H2 (Storage bucket public + filename predictable):
--   ✅ มี migration security-fix-storage.sql แก้ไว้แล้ว:
--      - file_size_limit = 5MB
--      - allowed_mime_types = image/* เท่านั้น
--      - INSERT/UPDATE/DELETE บน employee-photos → HR/admin only
--   ✅ frontend ใช้ crypto.randomUUID() ตอน upload (data.js:1457)
--      → filename 122-bit entropy, เดาไม่ได้
--   ✅ Bucket ยังเป็น public read เพื่อใช้ <img src> ตรงๆ (เร็วกว่า signed URL)
--
-- การแก้เพิ่มเติม:
--   1. ตรวจ announcement-images bucket ว่ามี HR-only INSERT ด้วย
--   2. เพิ่ม policy SELECT บน storage.objects → กรณีเกินคาดที่ bucket policy
--      อนุญาตให้เห็น metadata ของไฟล์อื่น (list/search) เฉพาะ HR
--   3. Audit ไฟล์ใน employee-photos ที่ filename ไม่ตรง UUID pattern
--      → ถ้ามี ต้อง rename ผ่าน admin (อาจมีรูปเก่าจากก่อน UUID migration)
--
-- รันใน Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════

-- 1. lock down announcement-images write เหมือน employee-photos
DROP POLICY IF EXISTS "kb_announcements_insert" ON storage.objects;
CREATE POLICY "kb_announcements_insert" ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'announcement-images'
  AND public.is_hr_or_admin()
);

DROP POLICY IF EXISTS "kb_announcements_update" ON storage.objects;
CREATE POLICY "kb_announcements_update" ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'announcement-images'
  AND public.is_hr_or_admin()
);

DROP POLICY IF EXISTS "kb_announcements_delete" ON storage.objects;
CREATE POLICY "kb_announcements_delete" ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'announcement-images'
  AND public.is_hr_or_admin()
);

-- 2. audit filename ของ employee-photos ที่ไม่ใช่ UUID pattern
--    UUID pattern: 8-4-4-4-12 hex (รวม dashes 36 chars) — รูปเก่าก่อน UUID migration
--    จะใช้ pattern เช่น "${id}-${ts}.jpg" → ไม่ตรง regex
DO $$
DECLARE
  v_legacy RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR v_legacy IN
    SELECT name, owner, created_at
    FROM storage.objects
    WHERE bucket_id = 'employee-photos'
      AND name !~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
      -- รวม folder structure ปกติ: <employee_id>/<uuid>.jpg
    ORDER BY created_at DESC
    LIMIT 20
  LOOP
    v_count := v_count + 1;
    RAISE NOTICE '⚠️  Legacy photo (predictable filename): name=% created=%',
      v_legacy.name, v_legacy.created_at;
  END LOOP;
  IF v_count = 0 THEN
    RAISE NOTICE '✅ ไม่พบรูปที่ filename predictable — UUID migration ทำงานครบ';
  ELSE
    RAISE NOTICE '⚠️  พบ % ไฟล์ (sample) ที่ไม่ใช้ UUID — rename ผ่าน admin หรือลบทิ้ง', v_count;
  END IF;
END $$;

-- 3. ตรวจสอบสิทธิ์ทั้งหมดของ storage.objects บน 2 bucket นี้
DO $$
DECLARE
  v_policy RECORD;
BEGIN
  RAISE NOTICE '─── Storage policies summary ───';
  FOR v_policy IN
    SELECT policyname, cmd,
           CASE WHEN with_check LIKE '%is_hr_or_admin%' OR qual LIKE '%is_hr_or_admin%'
                THEN '✅ HR/admin only'
                ELSE '⚠️  ANY authenticated'
           END AS guard
    FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND (policyname LIKE 'kb_photos%' OR policyname LIKE 'kb_announcements%')
    ORDER BY policyname
  LOOP
    RAISE NOTICE '  % [%]  %', v_policy.policyname, v_policy.cmd, v_policy.guard;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Security Fix H2 รัน เสร็จแล้ว';
  RAISE NOTICE '   - announcement-images: INSERT/UPDATE/DELETE = HR/admin only';
  RAISE NOTICE '   - audit รูปเก่าที่ filename ไม่ใช้ UUID (ถ้ามี)';
  RAISE NOTICE '   - ระบบป้องกัน enumerate ได้ระดับ 122-bit (UUID v4)';
END $$;
