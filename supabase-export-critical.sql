-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Export Critical Tables (Manual Backup)
--
-- วิธีใช้:
--   1. รันแต่ละ query ใน Supabase SQL Editor
--   2. คลิกผลลัพธ์ → "Export" → CSV/JSON  หรือ copy JSON column
--   3. เซฟลง encrypted drive (ห้าม commit git, ห้ามขึ้น public cloud)
--
-- ⚠️ ไฟล์ผลลัพธ์มี ปชช/เงินเดือน/bank — sensitive สูง เก็บปลอดภัย
--
-- หมายเหตุ: Supabase SQL user เขียนไฟล์ตรงไม่ได้ (no COPY TO file)
--   → ใช้ JSON aggregate แทน → copy ออกมาเซฟเอง
--   → สำหรับ full automated backup ใช้ Supabase CLI (ดู DISASTER-RECOVERY.md)
-- ═══════════════════════════════════════════════════════════

-- ─── 0. Backup metadata (รันก่อน — บันทึกว่า snapshot เมื่อไหร่ + row counts) ───
SELECT
  now() AS backup_timestamp,
  (SELECT count(*) FROM public.employees) AS employees,
  (SELECT count(*) FROM public.salary_history) AS salary_history,
  (SELECT count(*) FROM public.user_profiles) AS user_profiles,
  (SELECT count(*) FROM public.leave_requests) AS leave_requests,
  (SELECT count(*) FROM public.loans) AS loans,
  (SELECT count(*) FROM public.advances) AS advances,
  (SELECT count(*) FROM public.allowances) AS allowances,
  (SELECT count(*) FROM public.evaluations) AS evaluations,
  (SELECT count(*) FROM public.uniform_issues) AS uniform_issues,
  (SELECT count(*) FROM public.audit_log) AS audit_log;
-- 📸 เซฟผลนี้ไว้ → ใช้เทียบตอน restore test ว่า row ครบ

-- ═══════════════════════════════════════════════════════════
-- CRITICAL (🔴) — export ทุกครั้ง
-- ═══════════════════════════════════════════════════════════

-- ─── 1. employees (ทั้งหมด รวม resigned) ───
SELECT json_agg(row_to_json(e)) AS employees_json
FROM public.employees e;

-- ─── 2. salary_history ───
SELECT json_agg(row_to_json(s)) AS salary_history_json
FROM public.salary_history s;

-- ─── 3. user_profiles (สิทธิ์) ───
SELECT json_agg(row_to_json(up)) AS user_profiles_json
FROM public.user_profiles up;

-- ═══════════════════════════════════════════════════════════
-- HIGH (🟠)
-- ═══════════════════════════════════════════════════════════

-- ─── 4. leave_requests ───
SELECT json_agg(row_to_json(l)) AS leave_requests_json
FROM public.leave_requests l;

-- ─── 5. holiday_swap_requests ───
SELECT json_agg(row_to_json(h)) AS holiday_swap_json
FROM public.holiday_swap_requests h;

-- ─── 6. loans + advances + allowances (การเงิน) ───
SELECT json_agg(row_to_json(x)) AS loans_json FROM public.loans x;
SELECT json_agg(row_to_json(x)) AS advances_json FROM public.advances x;
SELECT json_agg(row_to_json(x)) AS allowances_json FROM public.allowances x;

-- ─── 7. evaluations ───
SELECT json_agg(row_to_json(x)) AS evaluations_json FROM public.evaluations x;

-- ═══════════════════════════════════════════════════════════
-- MEDIUM (🟡)
-- ═══════════════════════════════════════════════════════════

-- ─── 8. work schedule ───
SELECT json_agg(row_to_json(x)) AS schedule_weeks_json FROM public.schedule_weeks x;
SELECT json_agg(row_to_json(x)) AS schedule_entries_json FROM public.schedule_entries x;

-- ─── 9. uniform (items + requests + issues + movements) ───
SELECT json_agg(row_to_json(x)) AS uniform_items_json FROM public.uniform_items x;
SELECT json_agg(row_to_json(x)) AS uniform_requests_json FROM public.uniform_requests x;
SELECT json_agg(row_to_json(x)) AS uniform_issues_json FROM public.uniform_issues x;
SELECT json_agg(row_to_json(x)) AS uniform_movements_json FROM public.uniform_stock_movements x;

-- ─── 10. audit_log (90 วันล่าสุด — full อาจใหญ่) ───
SELECT json_agg(row_to_json(a)) AS audit_log_recent_json
FROM public.audit_log a
WHERE a.created_at >= now() - INTERVAL '90 days';

-- ═══════════════════════════════════════════════════════════
-- RBAC snapshot (🟢 — re-create ได้ แต่เก็บไว้สะดวก)
-- ═══════════════════════════════════════════════════════════
SELECT json_agg(row_to_json(x)) AS roles_json FROM public.roles x;
SELECT json_agg(row_to_json(x)) AS role_permissions_json FROM public.role_permissions x;

-- ═══════════════════════════════════════════════════════════
-- เสร็จแล้ว — เซฟทุกผลลัพธ์ลงไฟล์ (encrypted) + บันทึกวันที่
-- Restore: INSERT INTO <table> SELECT * FROM json_populate_recordset(NULL::<table>, '<json>')
-- ═══════════════════════════════════════════════════════════
