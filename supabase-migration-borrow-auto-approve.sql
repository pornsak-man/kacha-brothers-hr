-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Auto-Approve Cross-Branch Borrow
--
-- กรณีพิเศษ: ถ้า requester มีสิทธิ์ approve ทั้ง source + destination
-- (เช่น HR/admin, หรือ AM ที่ดูแลทั้ง 2 สาขา) → auto-approve ทันที
--
-- เหตุผล: ตัดขั้นตอน "อนุมัติตัวเอง" — ไม่มีประโยชน์ทาง audit เพิ่ม
-- เพราะ AM/HR คนเดียวจะเห็นทั้ง 2 ฝั่งอยู่แล้ว
--
-- รันใน Supabase SQL Editor (idempotent — รันซ้ำได้)
-- รันหลัง supabase-migration-cross-branch-borrow.sql เท่านั้น
-- ═══════════════════════════════════════════════════════════

-- ════════ 1. เพิ่ม column auto_approved ════════
ALTER TABLE public.cross_branch_borrow_requests
  ADD COLUMN IF NOT EXISTS auto_approved BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.cross_branch_borrow_requests.auto_approved IS
  'true = requester มีสิทธิ์ approve ทั้ง source+destination → auto-approve ตอนสร้าง';

-- ════════ 2. helper: เช็คว่า user คนนี้มีสิทธิ์ approve borrow ของ source branch นี้ไหม ════════
-- = AM/OM ที่ดูแลสาขา (รวม managed_branches override + emp.branch fallback)
CREATE OR REPLACE FUNCTION public.user_can_approve_source(p_source_branch TEXT)
RETURNS BOOLEAN
LANGUAGE PLPGSQL
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
  v_branches TEXT[];
  v_own_branch TEXT;
BEGIN
  IF public.is_hr_or_admin() THEN RETURN TRUE; END IF;
  SELECT up.role, up.managed_branches, e.branch
    INTO v_role, v_branches, v_own_branch
  FROM public.user_profiles up
  LEFT JOIN public.employees e ON e.id = up.employee_id
  WHERE up.user_id = auth.uid();
  IF v_role NOT IN ('area_manager', 'operation_manager') THEN
    RETURN FALSE;
  END IF;
  IF v_branches IS NOT NULL AND array_length(v_branches, 1) > 0 THEN
    RETURN p_source_branch = ANY(v_branches);
  END IF;
  RETURN v_own_branch = p_source_branch;
END $$;

-- ════════ 3. แก้ create_borrow_request — auto-approve ถ้ามีสิทธิ์ทั้ง 2 ฝั่ง ════════
CREATE OR REPLACE FUNCTION public.create_borrow_request(
  p_employee_id           TEXT,
  p_destination_branch_id TEXT,
  p_work_dates            DATE[],
  p_reason                TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_source_branch TEXT;
  v_new_id        UUID;
  v_can_dest      BOOLEAN;
  v_can_source    BOOLEAN;
  v_auto_approve  BOOLEAN;
  v_status        TEXT;
BEGIN
  -- 1) เช็คสิทธิ์: requester ต้องสร้าง schedule ของ destination ได้
  v_can_dest := public.can_create_schedule_for_branch(p_destination_branch_id);
  IF NOT v_can_dest THEN
    RAISE EXCEPTION 'ไม่มีสิทธิ์ขอยืมพนักงานเข้าสาขานี้';
  END IF;

  -- 2) หา source branch จาก employee
  SELECT branch INTO v_source_branch FROM public.employees WHERE id = p_employee_id;
  IF v_source_branch IS NULL THEN
    RAISE EXCEPTION 'ไม่พบพนักงาน %', p_employee_id;
  END IF;
  IF v_source_branch = p_destination_branch_id THEN
    RAISE EXCEPTION 'พนักงานคนนี้สังกัดสาขาปลายทางอยู่แล้ว — ไม่ต้องขอยืม';
  END IF;

  -- 3) validate dates
  IF p_work_dates IS NULL OR array_length(p_work_dates, 1) < 1 THEN
    RAISE EXCEPTION 'ต้องระบุวันทำงานอย่างน้อย 1 วัน';
  END IF;

  -- 4) ★ AUTO-APPROVE: ถ้า requester มีสิทธิ์ approve source ด้วย → อนุมัติเลย
  v_can_source := public.user_can_approve_source(v_source_branch);
  v_auto_approve := v_can_source;   -- HR/admin/AM ที่ดูแลทั้ง 2 ฝั่ง → true
  v_status := CASE WHEN v_auto_approve THEN 'approved' ELSE 'pending' END;

  INSERT INTO public.cross_branch_borrow_requests (
    employee_id, source_branch_id, destination_branch_id,
    work_dates, reason, requested_by,
    status, auto_approved,
    reviewed_by, reviewed_at, approver_note
  ) VALUES (
    p_employee_id, v_source_branch, p_destination_branch_id,
    p_work_dates, p_reason, auth.uid(),
    v_status, v_auto_approve,
    CASE WHEN v_auto_approve THEN auth.uid() ELSE NULL END,
    CASE WHEN v_auto_approve THEN now() ELSE NULL END,
    CASE WHEN v_auto_approve THEN 'อนุมัติอัตโนมัติ — ผู้สร้างคำขอมีสิทธิ์ดูแลทั้ง 2 สาขา' ELSE NULL END
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'id', v_new_id,
    'status', v_status,
    'auto_approved', v_auto_approve,
    'message', CASE
      WHEN v_auto_approve THEN 'อนุมัติอัตโนมัติ — ใส่กะให้พนักงานได้ทันที'
      ELSE 'ส่งคำขอแล้ว — รอ AM สาขาแม่อนุมัติ'
    END
  );
END $$;

GRANT EXECUTE ON FUNCTION public.create_borrow_request(TEXT, TEXT, DATE[], TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE '✅ Auto-Approve workflow ติดตั้งเสร็จ';
  RAISE NOTICE '   - column auto_approved (default false)';
  RAISE NOTICE '   - helper user_can_approve_source()';
  RAISE NOTICE '   - create_borrow_request: ตรวจสิทธิ์ทั้ง 2 ฝั่ง → auto-approve ถ้ามีครบ';
  RAISE NOTICE '';
  RAISE NOTICE '   เคสที่จะ auto-approve:';
  RAISE NOTICE '   1. HR/admin สร้างคำขอ (มีสิทธิ์ทุกสาขา)';
  RAISE NOTICE '   2. AM/OM ที่ managed_branches มีทั้ง source + destination';
  RAISE NOTICE '   3. AM/OM ที่ตัวเองสังกัด source + ดูแล destination';
  RAISE NOTICE '';
  RAISE NOTICE '   เคสที่ยังต้อง pending (รออนุมัติ):';
  RAISE NOTICE '   - BM สร้างคำขอ (สิทธิ์เฉพาะสาขาตัวเอง — ไม่ครอบ source อีก)';
  RAISE NOTICE '   - AM ที่ดูแลเฉพาะ destination (ไม่ดูแล source)';
END $$;
