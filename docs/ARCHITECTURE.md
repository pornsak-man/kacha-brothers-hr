# KACHA BROTHERS HR — Architecture & Security Documentation

> เอกสารสถาปัตยกรรมระบบ — สร้างจาก schema จริง (2026-05-27)
> ใช้เป็นแผนที่ของระบบเมื่อ logic ส่วนใหญ่อยู่ใน Database layer (Supabase Postgres)

## 📐 ภาพรวมสถาปัตยกรรม

```
┌─────────────────────────────────────────────────────────┐
│  Frontend: Static HTML/JS (GitHub Pages)                 │
│  - index.html · js/app.js (UI) · js/data.js (data layer) │
│  - ไม่มี backend server — เรียก Supabase ตรง             │
└───────────────────────────┬─────────────────────────────┘
                            │ supabase-js (REST + Realtime + Auth)
                            ▼
┌─────────────────────────────────────────────────────────┐
│  Supabase (BaaS)                                          │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │ Postgres    │  │ Auth (GoTrue)│  │ Storage         │  │
│  │ + RLS       │  │ JWT          │  │ (photos/images) │  │
│  │ + Triggers  │  │              │  │ public-read     │  │
│  │ + RPC funcs │  │              │  │ HR/admin write  │  │
│  └─────────────┘  └──────────────┘  └─────────────────┘  │
│         ↑ Security enforced HERE (ไม่ใช่ที่ client)       │
└─────────────────────────────────────────────────────────┘
```

**หลักการสำคัญ:** Logic อยู่ใน DB เพราะไม่มี backend server — RLS + triggers + SECURITY DEFINER functions คือชั้น enforcement เดียวที่ client bypass ไม่ได้ นี่เป็น **design ที่ถูกต้อง** สำหรับ static site + BaaS

---

## 🗂️ ER Diagram (Entity Relationships)

```
                          ┌──────────────┐
                          │ auth.users   │ (Supabase Auth)
                          └──────┬───────┘
                                 │ 1:1 (user_id)
                          ┌──────▼────────┐
          ┌───────────────┤ user_profiles │ role, employee_id, managed_branches
          │               └──────┬────────┘
          │                      │ employee_id (nullable)
          │                      ▼
┌─────────▼──────┐        ┌─────────────┐       ┌──────────────────┐
│ departments    │◄───────┤ employees   ├──────►│ position_levels  │
│ (manager_id ↩) │ dept   │ (TEXT PK)   │ pos   │                  │
└────────────────┘        └──────┬──────┘       └──────────────────┘
                                 │ employee_id (CASCADE)
       ┌─────────────┬───────────┼────────────┬──────────────┬─────────────┐
       ▼             ▼           ▼            ▼              ▼             ▼
┌───────────┐ ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌─────────────┐ ┌────────────┐
│salary_hist│ │ loans    │ │advances │ │allowances│ │ evaluations │ │leave_reqs  │
└───────────┘ └──────────┘ └─────────┘ └──────────┘ └─────────────┘ └────────────┘

┌──────────────────────────────── UNIFORM SUBSYSTEM ────────────────────────────────┐
│  uniform_brands (code PK)                                                          │
│       ↓ brand (TEXT, soft-ref)                                                     │
│  uniform_items (stock_qty, reorder_point, sku, color, category)                    │
│       ↓ item_id                                                                    │
│  uniform_requests ──(request_id)──► uniform_issues ──(ref_issue_id)──► movements   │
│  (employee_id / applicant_id,                          (immutable ledger:          │
│   brand_preference, request_type)                       receive/issue/return/adjust)│
└────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────── WORK SCHEDULE SUBSYSTEM ──────────────────────────────┐
│  shifts ──┐                                                                        │
│           ▼                                                                        │
│  schedule_weeks (branch, status: draft→submitted→approved) ──► schedule_entries    │
│       ▲                                                          (work_date, shift) │
│       │ cross-branch borrow                                                         │
│  cross_branch_borrow_requests (source/dest branch, status, auto_approved)          │
└────────────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────── RBAC SUBSYSTEM ───────────────────────────────────────┐
│  roles (7 system + custom) ──► role_permissions ◄── permissions (62 keys)          │
│       ▲ role_id = user_profiles.role                                               │
│  user_has_permission(key) → ใช้ขับ RLS ทั้งระบบ (Phase 5 pivot)                    │
└────────────────────────────────────────────────────────────────────────────────────┘

OTHER: holiday_swap_requests · calendar_items · company_announcements ·
       announcement_reads · applicants · employee_blacklist · audit_log ·
       company_settings · position_scopes · leave_types · role_permission_matrix(legacy)
```

**FK Cascade ที่สำคัญ:**
- `employees` ถูกลบ → ข้อมูลการเงิน/ลา/ประเมิน CASCADE ตาม (ระวัง! ปกติใช้ `status='resigned'` แทนการลบ)
- `auth.users` ถูกลบ → `user_profiles` CASCADE
- `uniform_requests` ถูกลบ → `uniform_issues` CASCADE → trigger คืน stock

---

## 🔐 RLS Matrix (สิทธิ์การเข้าถึงข้อมูล)

> **Role ทั้ง 7:** `admin` · `hr` · `operation_manager` (OM) · `area_manager` (AM) · `branch_manager` (BM) · `branch_staff` · `viewer`

### กลุ่มข้อมูลพนักงาน (sensitive)

| Table | SELECT (ใครเห็น) | WRITE (ใครแก้) |
|-------|-----------------|----------------|
| `employees` | HR/admin = ทุกคน · OM/AM/BM = ตาม managed_branches (fallback สาขาตัวเอง) · staff/viewer = **ตัวเองเท่านั้น** | `is_hr_or_admin()` |
| `employees_view` | (เหมือน employees) + **column masking**: salary/ปชช/bank/sso → NULL ถ้าไม่ใช่ HR | — (read-only view) |
| `salary_history` | permission `salary.view_history` | permission `salary.adjust` |
| `loans/advances/allowances/evaluations` | HR/admin/OM = ทุกคน · AM/BM = ตามสาขา · staff = ตัวเอง | `is_hr_or_admin()` |

### กลุ่ม Self-service (พนักงานยื่นเอง)

| Table | SELECT | INSERT | UPDATE |
|-------|--------|--------|--------|
| `leave_requests` | HR/OM/approver/เจ้าตัว/manager-by-branch | เจ้าตัว (status=pending, ห้ามตั้ง approver) | HR/approver/เจ้าตัว(pending→cancelled เท่านั้น) |
| `holiday_swap_requests` | (เหมือน leave) | (เหมือน leave) | (เหมือน leave) |
| `uniform_requests` | HR/admin OR เจ้าตัว | เจ้าตัว (pending, total_cost=0, ไม่มี applicant_id) | เจ้าตัว pending→cancelled |

**Anti-tamper:** มี trigger ป้องกันเจ้าตัวแก้ฟิลด์ approver หรือ self-approve

### กลุ่มตารางงาน

| Table | SELECT | WRITE |
|-------|--------|-------|
| `schedule_weeks` | admin/hr/OM OR สาขาตัวเอง | admin/hr/OM OR BM/AM ของสาขานั้น |
| `schedule_entries` | admin/hr/OM OR สาขาเดียวกัน OR row ตัวเอง | BM/AM ของสาขา + **trigger บังคับ borrow approved สำหรับข้ามสาขา** |
| `cross_branch_borrow_requests` | คู่กรณี (source/dest) | INSERT: ต้องผ่าน review (auto_approved=false) · DELETE: admin |

### กลุ่ม Master / Public

| Table | SELECT | WRITE |
|-------|--------|-------|
| `user_profiles` | **ทุกคน (org chart)** | UPDATE own + **trigger บล็อก self role/branch escalation** · INSERT/DELETE admin |
| `uniform_items/brands` | ทุกคน | `is_hr_or_admin()` (หรือ RPC) |
| `uniform_stock_movements` | ทุกคน | INSERT only (HR) — **immutable ledger ห้าม UPDATE/DELETE** |
| `departments/position_levels/shifts/calendar_items/announcements` | ทุกคน | `is_hr_or_admin()` |
| `applicants/employee_blacklist` | `is_hr_or_admin()` | `is_hr_or_admin()` |
| `company_settings` | ทุกคน | **`is_admin()` เท่านั้น** |
| `audit_log` | permission `system.view_audit` | trigger-only (ไม่มี user write) |

---

## 🎫 Permission Model (RBAC แบบ Dynamic)

### โครงสร้าง 2 ชั้น

```
user_profiles.role (TEXT) ──┐
                            │ role_id
                            ▼
        roles (7 system + custom) ──► role_permissions ◄── permissions (62 keys)
                                       (role_id, permission_key, granted)
                                            │
                                            ▼
                              user_has_permission('key') → boolean
                                            │
                            ┌───────────────┴────────────────┐
                            ▼                                 ▼
                  is_admin() = ...                  is_hr_or_admin() = ...
                  'permission.edit_matrix'          'employee.edit' OR edit_matrix
                            │                                 │
                            └──────────► ขับ RLS ทั้งระบบ ◄────┘
```

### ⭐ Phase 5 Pivot (สำคัญต่อการ debug)

`supabase-migration-permissions-v1-phase5-rls.sql` **เปลี่ยนนิยาม** `is_admin()` / `is_hr_or_admin()` ให้ delegate ไปที่ permission matrix → policy ~100 ตัวเปลี่ยนพฤติกรรมพร้อมกันโดยไม่ต้องแก้ทีละตัว

**ผลคือ:** เปิด/ปิด permission ในหน้า admin → RLS เปลี่ยนพฤติกรรมทันที (multi-device ผ่าน realtime)

### ⚠️ ข้อสังเกต (Documentation Debt ที่ควรรู้)

มี **divergence** ที่ควร flag:
- RLS policies ใช้ `is_hr_or_admin()` = permission-matrix-based (dynamic)
- แต่ `employees_view` column masking ใช้ `is_hr_or_admin_cached()` = role-based (`role IN ('admin','hr')`)

→ ถ้าสร้าง custom role ที่มี `employee.edit` แต่ไม่ใช่ role 'hr'/'admin' → จะเห็น row (RLS ผ่าน) **แต่ column sensitive ถูก mask** (view ใช้ cached role check)

**คำแนะนำ:** ถ้าจะใช้ custom role จัดการ employee → ต้อง sync logic ของ `is_hr_or_admin_cached()` ให้ตรงกับ matrix หรือเพิ่ม custom role เข้า cached check

### Permission flags (anti-lockout)

- `is_critical` — permission ที่ห้าม role ใดถอด (กัน lockout) เช่น `permission.edit_matrix`
- `is_dangerous` — UI ต้อง double-confirm + protected role ถอดไม่ได้
- `roles.is_system` — 7 roles หลักลบไม่ได้ · `roles.is_protected` — admin role ถอด dangerous perm ไม่ได้

---

## 🔄 Approval Chains (สายอนุมัติ)

### Leave / Holiday Swap
```
พนักงานยื่น (status=pending)
   │
   ▼
leave_approver_for(emp_id) คำนวณผู้อนุมัติ:
   1. หัวหน้าสาขา (top position holder ในสาขา)
   2. → ถ้าไม่มี → Area Manager ที่ดูแลสาขา
   3. → fallback → HR
   (กันself-approve: ผู้ยื่น ≠ ผู้อนุมัติเสมอ)
   │
   ▼
approver/HR/admin กดอนุมัติ → status=approved → (swap: apply เข้า calendar)
```

### Schedule (ตารางงาน)
```
BM จัดตาราง (draft) → "ส่งขออนุมัติ" (submitted)
   │
   ▼
AM ที่ดูแลสาขา (canApproveScheduleForBranch) → อนุมัติ (approved)
   │
   ▼ ข้ามสาขา?
cross_branch_borrow_requests ต้อง approved ก่อน
→ trigger fn_enforce_borrow_approved บล็อกถ้ายังไม่ผ่าน
```

### Uniform (จัดชุด)
```
3 แหล่งคำขอ → uniform_requests (pending)
   ├─ Recruit (applicant) → request_type=new_hire
   ├─ Self-service (พนักงาน) → request_type=damaged/lost/periodic/extra
   └─ HR direct
   │
   ▼
HR จัดชุด (uniform_issues)
   ▼ trigger #1: fill snapshot (brand/color/sku จาก item)
   ▼ trigger #2: stock deduct (atomic, FOR UPDATE lock, check พอ)
   ▼ INSERT movement (type=issue, ลง ledger)
```

---

## ⚡ Triggers Map

| Table | Trigger | Timing | หน้าที่ |
|-------|---------|--------|--------|
| `auth.users` | on_auth_user_created | AFTER INSERT | สร้าง user_profiles (viewer) |
| `user_profiles` | guard_self_update | BEFORE UPDATE | บล็อก self role/branch escalation |
| `employees` | sync_termination_to_auth | AFTER UPD termination_date | ban auth + revoke token เมื่อพ้นสภาพ |
| `leave_requests` | anti_tamper | BEFORE UPDATE | กันแก้ approver field / self-approve |
| `schedule_entries` | enforce_borrow_approved | BEFORE INS/UPD | บล็อกข้ามสาขาถ้าไม่มี borrow approved |
| `uniform_issues` | fill_snapshot (a_*) | BEFORE INS/UPD | เติม brand/color/sku จาก item |
| `uniform_issues` | stock_trigger | BEFORE INS/UPD/DEL | ตัด/คืน stock + ลง ledger + check พอ |
| `role_permissions` | audit | AFTER INS/UPD/DEL | log การเปลี่ยน permission matrix |
| ~15 master tables | audit_trigger | AFTER INS/UPD/DEL | log → audit_log (redact PII) |

---

## 🛡️ Defense in Depth (ชั้นความปลอดภัย)

1. **RLS row gates** — ใครเห็น row ไหน
2. **employees_view column masking** — sensitive cols → NULL ถ้าไม่ใช่ HR
3. **BEFORE-UPDATE anti-tamper triggers** — กันแก้ฟิลด์ต้องห้าม
4. **SECURITY DEFINER RPCs** (`SET search_path`) — privileged writes ผ่าน function เท่านั้น
5. **audit_log** — บันทึกทุกการเปลี่ยนแปลง (redact PII อัตโนมัติ)

**Residual risk ที่รู้ตัว:** base table `employees` ยัง SELECT ได้ (เพื่อ realtime/org-chart) → column secrecy พึ่ง `employees_view` → ถ้า non-HR query `from('employees')` ตรง จะได้ row (scoped) แต่ REVOKE column ยัง deferred (ดู `m1-employees-view.sql`)

---

## 📚 ไฟล์ migration สำคัญ (final state)

| ด้าน | ไฟล์ |
|------|------|
| Core schema | `supabase-schema.sql` |
| RBAC pivot | `supabase-migration-permissions-v1.sql` + `...-phase5-rls.sql` |
| Employee RLS | `...-security-fix-c4-employees-rls-strict.sql` + `...-c4-fix-bm-own-branch.sql` |
| Leave security | `...-leave-security.sql` + `...-leave-anti-tamper.sql` + `...-leave-chain-rls-expand.sql` |
| Org chart | `...-user-profiles-public-read.sql` + `...-org-chart-rpc.sql` |
| Uniform stock | `...-uniform-stock-trigger.sql` → `...-stock-movements.sql` → `...-issues-snapshot.sql` |
| Perf cache | `...-fix-is-hr-session-cache.sql` |

> ลำดับ setup DB ใหม่: ดู `UNIFORM-STOCK-MIGRATION-CHECKLIST.md` (uniform) + `docs/MIGRATION-INDEX.md` (ทั้งระบบ)
