-- ═══════════════════════════════════════════════════════════════════════
-- RECOVERY — กู้ positionTitle ของพนักงานหลังกดปุ่ม "ซิงค์ snapshot" ผิด
-- ─────────────────────────────────────────────────────────────────────
-- บั๊กที่เกิด:
--   ปุ่ม syncAllPositionTitles() (เพิ่งลบออกจาก UI แล้ว) ทับ positionTitle
--   ตาม position.name ปัจจุบัน — โดย assume FK เป็น truth
--   แต่ในข้อมูล legacy บางพนักงาน FK ชี้ผิด → snapshot "RM" หาย
--
-- วิธีกู้:
--   audit_log มี old_data + new_data ของทุก UPDATE บน employees
--   → rollback position_title กลับเป็นค่าเดิมจาก old_data
--
-- รันใน Supabase SQL Editor (admin เท่านั้น — RLS ของ audit_log)
-- รันทีละ STEP — มี SELECT ดูก่อน UPDATE ทุกครั้ง
-- ═══════════════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════
-- STEP 1 — สำรวจ: ดู UPDATEs ของ employees ที่ position_title เปลี่ยน ใน 24 ชั่วโมงที่ผ่านมา
-- ═══════════════════════════════════════════════════════════
-- ดูว่าเป็น batch sync จริงไหม (น่าจะเห็นเวลาใกล้กันมาก + เปลี่ยนหลายคนพร้อมกัน)
SELECT
  ts,
  record_id                          AS employee_id,
  old_data->>'position_title'        AS old_title,
  new_data->>'position_title'        AS new_title,
  old_data->>'position'              AS position_fk,
  user_email
FROM audit_log
WHERE table_name = 'employees'
  AND action     = 'UPDATE'
  AND (old_data->>'position_title') IS DISTINCT FROM (new_data->>'position_title')
  AND ts > now() - INTERVAL '24 hours'
ORDER BY ts DESC;


-- ═══════════════════════════════════════════════════════════
-- STEP 2 — สรุปการเปลี่ยนแปลง (group by old → new)
-- ═══════════════════════════════════════════════════════════
-- ดูว่ามี pattern ไหน — เช่น "RM" → "Officer" 10 คน, "Act.RM" → "Officer" 5 คน
SELECT
  old_data->>'position_title'  AS old_title,
  new_data->>'position_title'  AS new_title,
  COUNT(*)                      AS affected_count,
  MIN(ts)                       AS first_change,
  MAX(ts)                       AS last_change
FROM audit_log
WHERE table_name = 'employees'
  AND action     = 'UPDATE'
  AND (old_data->>'position_title') IS DISTINCT FROM (new_data->>'position_title')
  AND ts > now() - INTERVAL '24 hours'
GROUP BY old_data->>'position_title', new_data->>'position_title'
ORDER BY affected_count DESC;


-- ═══════════════════════════════════════════════════════════
-- STEP 3 — Preview rollback: ดูพนักงานที่จะถูก rollback ก่อน execute
-- ═══════════════════════════════════════════════════════════
-- ปรับ TIMESTAMP ให้แคบลงตามผล STEP 2 (แนะนำ: ใช้ first_change/last_change แทน '24 hours')
-- เปลี่ยน '2026-05-23 22:50:00+07' เป็นเวลาที่ใกล้กับการ sync จริง
WITH latest_change AS (
  SELECT DISTINCT ON (record_id)
    record_id,
    old_data->>'position_title'  AS old_title,
    new_data->>'position_title'  AS new_title,
    ts
  FROM audit_log
  WHERE table_name = 'employees'
    AND action     = 'UPDATE'
    AND (old_data->>'position_title') IS DISTINCT FROM (new_data->>'position_title')
    AND ts > now() - INTERVAL '24 hours'   -- ← ปรับช่วงเวลาตามผล STEP 2
  ORDER BY record_id, ts DESC
)
SELECT
  e.id,
  e.first_name || ' ' || COALESCE(e.last_name, '') AS name,
  e.position_title                                  AS current_title,
  lc.new_title                                      AS will_replace,
  lc.old_title                                      AS will_restore_to,
  lc.ts                                             AS changed_at
FROM employees e
JOIN latest_change lc ON e.id = lc.record_id
WHERE e.position_title = lc.new_title  -- เฉพาะที่ยังเป็นค่าใหม่ (ไม่ถูกแก้ทับอีก)
ORDER BY lc.old_title, e.id;


-- ═══════════════════════════════════════════════════════════
-- STEP 4 — EXECUTE rollback (ทำก็ต่อเมื่อ STEP 3 แสดงผลถูกต้อง!)
-- ═══════════════════════════════════════════════════════════
-- ⚠️ คำสั่งนี้จะ UPDATE จริง — ตรวจ STEP 3 ก่อนรัน
-- ตัวอย่าง: rollback "Officer" → "RM", "Officer" → "Act.RM" ฯลฯ
WITH latest_change AS (
  SELECT DISTINCT ON (record_id)
    record_id,
    old_data->>'position_title'  AS old_title,
    new_data->>'position_title'  AS new_title
  FROM audit_log
  WHERE table_name = 'employees'
    AND action     = 'UPDATE'
    AND (old_data->>'position_title') IS DISTINCT FROM (new_data->>'position_title')
    AND ts > now() - INTERVAL '24 hours'   -- ← ปรับให้ตรงกับ STEP 3
  ORDER BY record_id, ts DESC
)
UPDATE employees e
SET position_title = lc.old_title
FROM latest_change lc
WHERE e.id = lc.record_id
  AND e.position_title = lc.new_title;   -- กันชน: rollback เฉพาะที่ยังเป็นค่าใหม่ (ไม่ทับงานที่ HR แก้ใหม่หลัง bug)


-- ═══════════════════════════════════════════════════════════
-- STEP 5 — ตรวจผล: ดูจำนวนพนักงานแยกตาม positionTitle หลัง rollback
-- ═══════════════════════════════════════════════════════════
SELECT position_title, COUNT(*) AS count
FROM employees
WHERE status = 'active' OR status IS NULL
GROUP BY position_title
ORDER BY count DESC;


-- ═══════════════════════════════════════════════════════════
-- STEP 6 (เผื่อ) — ถ้าตำแหน่ง RM/Act.RM ถูก DELETE จาก position_levels จริง → กู้คืน
-- ═══════════════════════════════════════════════════════════
-- ดูก่อนว่ามี DELETE record ไหม
SELECT ts, record_id, old_data
FROM audit_log
WHERE table_name = 'position_levels'
  AND action     = 'DELETE'
  AND ts > now() - INTERVAL '7 days'
ORDER BY ts DESC;

-- ถ้ามี → INSERT กลับ (ใช้ id ใหม่ถ้า id เดิมถูกใช้ไปแล้ว — เปลี่ยน 'P16'/'P17' ตามว่ายังว่างไหม)
-- *** ตรวจสอบว่า 'P01'/'P02' ปัจจุบันยังว่างไหม ก่อน insert ***
--
-- ตัวอย่าง (ปรับ id ตามข้อมูลจริง):
-- INSERT INTO position_levels (id, name, level, min_salary, max_salary, scope)
-- VALUES
--   ('P16', 'RM',    8, 0, 0, 'operation'),
--   ('P17', 'Act.RM', 7, 0, 0, 'operation');
--
-- หมายเหตุ: ถ้าจะใช้ id เก่า (P01/P02) ต้องลบ/rename records ปัจจุบันก่อน
-- — แต่ใช้ id ใหม่ปลอดภัยกว่า (พนักงานยังคง FK เดิมไปที่ P01 = Officer ตามที่ตั้งใจ)
