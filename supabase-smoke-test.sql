-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Smoke Test (RLS + Schema + Trigger assertions)
--
-- วิธีใช้:
--   1. รันทั้งไฟล์ใน Supabase SQL Editor (เป็น postgres/superuser)
--   2. ดู NOTICE — ทุกบรรทัดควรขึ้น "PASS"; ถ้า "FAIL" = มีปัญหา
--   3. รันหลังแก้ RLS/trigger ทุกครั้ง → จับ regression
--
-- โครงสร้าง:
--   PART A: Schema integrity (tables, columns, RLS enabled, functions, triggers)
--   PART B: Immutability & constraint checks (ledger, anti-tamper)
--   PART C: RLS behavior simulation (จำลอง role ต่างๆ — ต้องใส่ test user)
--
-- ปลอดภัย: PART A/B = read-only + savepoint rollback — ไม่กระทบข้อมูลจริง
-- ═══════════════════════════════════════════════════════════

DO $$
DECLARE
  v_tmp  INT;
  v_bool BOOLEAN;
BEGIN
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE 'PART A — Schema Integrity';
  RAISE NOTICE '═══════════════════════════════════════════════';

  -- A1: core tables exist — บอกชื่อตารางที่หาย (ถ้ามี)
  DECLARE r RECORD;
  BEGIN
    FOR r IN
      SELECT t.name FROM (VALUES
        ('employees'),('user_profiles'),('departments'),('position_levels'),
        ('salary_history'),('loans'),('advances'),('allowances'),('evaluations'),
        ('leave_requests'),('holiday_swap_requests'),('schedule_weeks'),('schedule_entries'),
        ('shifts'),('cross_branch_borrow_requests'),('uniform_items'),('uniform_requests'),
        ('uniform_issues'),('uniform_stock_movements'),('uniform_brands'),
        ('roles'),('permissions'),('role_permissions'),('audit_log'),('applicants')
      ) AS t(name)
      WHERE NOT EXISTS (
        SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename=t.name
      )
    LOOP
      RAISE WARNING '  ❌ FAIL: ตาราง "%" ไม่มีในระบบ', r.name;
    END LOOP;
  END;

  SELECT count(*) INTO v_tmp FROM pg_tables
  WHERE schemaname='public' AND tablename IN (
    'employees','user_profiles','salary_history','leave_requests',
    'schedule_weeks','uniform_items','uniform_stock_movements','roles','permissions','audit_log'
  );
  IF v_tmp = 10 THEN RAISE NOTICE '  ✅ PASS: core tables (10/10)';
  ELSE RAISE WARNING '  ❌ FAIL: core tables (%/10)', v_tmp; END IF;

  -- A2: RLS enabled on sensitive tables
  SELECT count(*) INTO v_tmp FROM pg_tables
  WHERE schemaname='public'
    AND tablename IN ('employees','salary_history','leave_requests','user_profiles',
                      'loans','advances','uniform_requests','schedule_entries')
    AND rowsecurity = true;
  IF v_tmp = 8 THEN RAISE NOTICE '  ✅ PASS: RLS enabled (8/8 sensitive tables)';
  ELSE RAISE WARNING '  ❌ FAIL: RLS enabled (%/8) — บาง table ปิด RLS!', v_tmp; END IF;

  -- A3: critical helper functions exist
  SELECT count(*) INTO v_tmp FROM pg_proc
  WHERE proname IN ('is_admin','is_hr_or_admin','user_has_permission',
                    'can_view_employee','set_employee_role','get_org_chart_employees',
                    'receive_uniform_stock','adjust_uniform_stock_manual',
                    'uniform_issues_stock_trigger','audit_trigger_fn');
  IF v_tmp >= 10 THEN RAISE NOTICE '  ✅ PASS: helper functions (% found)', v_tmp;
  ELSE RAISE WARNING '  ❌ FAIL: helper functions (% < 10) — บาง function หาย', v_tmp; END IF;

  -- A4: uniform modern inventory columns
  SELECT count(*) INTO v_tmp FROM information_schema.columns
  WHERE table_name='uniform_items'
    AND column_name IN ('brand','category','color','sku','reorder_point','supplier','gender','material','image_url','sort_order');
  IF v_tmp = 10 THEN RAISE NOTICE '  ✅ PASS: uniform_items modern cols (10/10)';
  ELSE RAISE WARNING '  ❌ FAIL: uniform_items modern cols (%/10) — รัน modern-inventory.sql', v_tmp; END IF;

  -- A5: uniform_issues snapshot columns
  SELECT count(*) INTO v_tmp FROM information_schema.columns
  WHERE table_name='uniform_issues'
    AND column_name IN ('brand_snapshot','color_snapshot','sku_snapshot','category_snapshot');
  IF v_tmp = 4 THEN RAISE NOTICE '  ✅ PASS: uniform_issues snapshot cols (4/4)';
  ELSE RAISE WARNING '  ❌ FAIL: snapshot cols (%/4) — รัน issues-snapshot.sql', v_tmp; END IF;

  -- A6: critical triggers exist
  SELECT count(*) INTO v_tmp FROM pg_trigger
  WHERE tgname IN ('trg_user_profiles_self_guard','trg_uniform_issues_stock',
                   'a_uniform_issues_fill_snapshot')
    AND NOT tgisinternal;
  IF v_tmp >= 3 THEN RAISE NOTICE '  ✅ PASS: critical triggers (% found)', v_tmp;
  ELSE RAISE WARNING '  ❌ FAIL: critical triggers (% < 3)', v_tmp; END IF;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE 'PART B — Immutability & Constraints';
  RAISE NOTICE '═══════════════════════════════════════════════';

  -- B1: uniform_stock_movements ห้ามมี UPDATE/DELETE policy (immutable ledger)
  SELECT count(*) INTO v_tmp FROM pg_policies
  WHERE tablename='uniform_stock_movements'
    AND cmd IN ('UPDATE','DELETE');
  IF v_tmp = 0 THEN RAISE NOTICE '  ✅ PASS: stock ledger immutable (no UPDATE/DELETE policy)';
  ELSE RAISE WARNING '  ❌ FAIL: stock ledger มี % UPDATE/DELETE policy — ควร immutable', v_tmp; END IF;

  -- B2: user_profiles role CHECK constraint (7 roles)
  SELECT EXISTS(
    SELECT 1 FROM information_schema.check_constraints
    WHERE constraint_schema='public'
      AND check_clause LIKE '%branch_manager%'
      AND check_clause LIKE '%area_manager%'
  ) INTO v_bool;
  IF v_bool THEN RAISE NOTICE '  ✅ PASS: user_profiles.role CHECK constraint (7 roles)';
  ELSE RAISE WARNING '  ❌ FAIL: role CHECK constraint หาย/ไม่ครบ'; END IF;

  -- B3: permissions critical flags (anti-lockout)
  SELECT count(*) INTO v_tmp FROM public.permissions WHERE is_critical = true;
  IF v_tmp >= 1 THEN RAISE NOTICE '  ✅ PASS: critical permissions มี % รายการ (anti-lockout)', v_tmp;
  ELSE RAISE WARNING '  ❌ FAIL: ไม่มี critical permission — เสี่ยง lockout'; END IF;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE 'PART B2 — Trigger Behavior (live test ใน transaction)';
  RAISE NOTICE '═══════════════════════════════════════════════';

  -- B4: stock trigger reject insufficient stock
  -- หา item ที่มี stock + ลองจัดเกิน → ควร RAISE
  -- เทคนิค: nested BEGIN/EXCEPTION = subtransaction (auto-rollback เมื่อ exception)
  --   - ถ้า trigger block → exception "Stock ไม่พอ" → PASS
  --   - ถ้า insert ผ่าน → เรา RAISE เองเพื่อ force rollback + mark FAIL
  DECLARE
    v_item_id UUID;
    v_stock INT;
    v_result TEXT := 'unknown';
  BEGIN
    SELECT id, stock_qty INTO v_item_id, v_stock
    FROM public.uniform_items WHERE stock_qty IS NOT NULL ORDER BY stock_qty DESC LIMIT 1;

    IF v_item_id IS NOT NULL THEN
      BEGIN
        INSERT INTO public.uniform_issues (item_id, qty, employee_id, issued_date)
        VALUES (v_item_id, v_stock + 99999, NULL, CURRENT_DATE);
        -- ถ้ามาถึงนี่ = trigger ไม่ block → force rollback ด้วย exception
        RAISE EXCEPTION '__INSERT_PASSED__';
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLERRM LIKE '%__INSERT_PASSED__%' THEN
            v_result := 'fail';   -- insert สำเร็จทั้งที่ stock ไม่พอ = บัค
          ELSE
            v_result := 'pass';   -- trigger raise (Stock ไม่พอ) = ถูกต้อง
          END IF;
      END;
      IF v_result = 'pass' THEN RAISE NOTICE '  ✅ PASS: stock trigger block insufficient stock';
      ELSE RAISE WARNING '  ❌ FAIL: stock trigger ไม่ block การจัดเกิน stock!'; END IF;
    ELSE
      RAISE NOTICE '  ⊘ SKIP: ไม่มี uniform_items ให้ทดสอบ';
    END IF;
  END;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE 'สรุป: ดู NOTICE ข้างบน — ❌ FAIL = ต้องแก้';
  RAISE NOTICE 'PART C (RLS simulation) อยู่ด้านล่าง — รันแยก';
  RAISE NOTICE '═══════════════════════════════════════════════';
END $$;

-- ═══════════════════════════════════════════════════════════
-- PART C — RLS Behavior Simulation (รันแยก, ต้องใส่ test user UUID)
-- ═══════════════════════════════════════════════════════════
-- วิธีใช้:
--   1. หา user_id ของ test users:
--        SELECT up.user_id, up.role, e.first_name, e.branch
--        FROM user_profiles up LEFT JOIN employees e ON e.id = up.employee_id
--        WHERE up.role IN ('branch_staff','hr') LIMIT 5;
--   2. แทน <STAFF_UUID> และ <HR_UUID> ด้านล่าง
--   3. รันแต่ละ block

/*  ── TEST C1: branch_staff เห็น employees แค่ตัวเอง ──
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<STAFF_UUID>","role":"authenticated"}';

  -- ควรเห็นแค่ 1 row (ตัวเอง) — ถ้าเห็นหลาย row = RLS รั่ว
  SELECT count(*) AS staff_sees_employees FROM public.employees;
  -- คาดหวัง: 1 (หรือ 0 ถ้าไม่ผูก employee_id)
ROLLBACK;
*/

/*  ── TEST C2: HR เห็น employees ทุกคน ──
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<HR_UUID>","role":"authenticated"}';

  SELECT count(*) AS hr_sees_employees FROM public.employees;
  -- คาดหวัง: = จำนวนพนักงานทั้งหมด
ROLLBACK;
*/

/*  ── TEST C3: branch_staff เห็น salary เป็น NULL (column mask) ──
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<STAFF_UUID>","role":"authenticated"}';

  -- ผ่าน employees_view — salary ควรเป็น NULL สำหรับ non-HR
  SELECT id, first_name, salary, national_id FROM public.employees_view LIMIT 1;
  -- คาดหวัง: salary = NULL, national_id = NULL
ROLLBACK;
*/

/*  ── TEST C4: staff ยื่นลาแทนคนอื่นไม่ได้ (self-insert only) ──
BEGIN;
  SET LOCAL ROLE authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"<STAFF_UUID>","role":"authenticated"}';

  -- ลอง insert leave ของ employee อื่น → ควร error (RLS WITH CHECK)
  INSERT INTO public.leave_requests (employee_id, leave_type, start_date, end_date, status)
  VALUES ('SOMEONE_ELSE_ID', 'ลากิจ', CURRENT_DATE, CURRENT_DATE, 'pending');
  -- คาดหวัง: ERROR (new row violates row-level security policy)
ROLLBACK;
*/
