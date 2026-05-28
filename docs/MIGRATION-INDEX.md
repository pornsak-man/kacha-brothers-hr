# Migration Index — ลำดับการรัน + สถานะ

> รวบรวม 99 migration files เป็น index ตามลำดับ dependency + subsystem
> ใช้เมื่อต้อง setup DB ใหม่ หรือเข้าใจว่าไฟล์ไหนทับไฟล์ไหน

## ⚠️ ข้อควรรู้ก่อน

migration ของระบบนี้เป็น **idempotent SQL** (ใช้ `IF NOT EXISTS` / `DROP ... IF EXISTS` / `CREATE OR REPLACE`) — รันซ้ำได้ ไม่ใช่ versioned framework แบบ Rails/Prisma

**ดังนั้น:** ไฟล์ภายหลังมัก**ทับ (override)** ไฟล์ก่อนหน้า — ต้องรันตามลำดับด้านล่างเพื่อให้ได้ final state ที่ถูกต้อง

---

## 🎯 วิธี Setup DB ใหม่ (2 ทางเลือก)

### ทางเลือก A: Generate baseline จริงจาก DB ปัจจุบัน (แนะนำ)
แทนการรัน 99 ไฟล์ — dump schema จริงจาก Supabase ที่ทำงานอยู่:

```bash
# ผ่าน Supabase CLI (ติดตั้ง: npm i -g supabase)
supabase db dump --db-url "postgresql://postgres:[PASSWORD]@db.xvulimfftkoiybvqdjqz.supabase.co:5432/postgres" \
  --schema public -f schema-baseline.sql

# หรือผ่าน Dashboard → Database → Backups → Download
```

baseline ที่ได้ = **ground truth** (state จริงหลังรันทุก migration) → ใช้ setup environment ใหม่ได้ทันทีไฟล์เดียว

> ⚠️ อย่า hand-merge 99 ไฟล์เอง — เสี่ยง diverge จาก DB จริง (override order ซับซ้อน) ให้ใช้ pg_dump เท่านั้น

### ทางเลือก B: รันตามลำดับ index ด้านล่าง (ถ้าเริ่มจาก 0)

---

## 📋 ลำดับการรัน (ตาม subsystem)

### 0️⃣ Foundation
| ไฟล์ | หมายเหตุ |
|------|---------|
| `supabase-schema.sql` | **เริ่มที่นี่** — core tables (employees, user_profiles, etc.) + is_admin/is_hr_or_admin เวอร์ชันแรก |

### 1️⃣ Org Structure
```
branches.sql → branches-contact.sql
position-levels.sql → position-scopes.sql → position-dept-scope.sql
departments-fk-cascade.sql → departments-hr-write.sql → seed-departments-fnb.sql
bulk-set-operation-dept.sql
```

### 2️⃣ Employee Fields
```
employee-fields.sql · address-parts.sql · allowance-phone.sql · foreign-docs.sql
termination.sql → termination-reason.sql → terminated-block-login.sql
sso.sql → sso-smart-backdate.sql
default-branch-staff.sql · employee-changes.sql
```

### 3️⃣ RBAC / Permissions (สำคัญ — ลำดับห้ามสลับ)
```
permissions-v1.sql
  → permissions-v1-patch-critical.sql       (anti-lockout flags)
  → permissions-v1-patch-role-crud.sql      (custom role CRUD)
  → permissions-v1-phase5-rls.sql           ⭐ PIVOT: is_admin/is_hr_or_admin → matrix
  → permissions-v2-missing-keys.sql         (เพิ่ม keys ที่ขาด)
rbac-hierarchy.sql → rbac-final.sql         (7-role hierarchy)
role-matrix.sql                             [LEGACY — superseded by permissions-v1]
rls-scope.sql
```

### 4️⃣ Employee Accounts (Auth)
```
employee-accounts.sql
  → -fix.sql → -fix2.sql → -fix3.sql → -fix4.sql   (แก้ต่อเนื่อง — รันครบ)
reset-password-default-natid.sql
```

### 5️⃣ Audit
```
audit-log.sql → step17-audit-retention.sql
```

### 6️⃣ Security Fixes (C/H/M series — รันหลัง core ครบ)
```
security-fix-critical.sql
security-fix-c2-no-plaintext-pwd.sql
security-fix-c4-employees-rls-strict.sql → c4-fix-bm-own-branch.sql
security-fix-c5-trigger.sql
security-fix-h2-storage-verify.sql
security-fix-h3-revoke-tokens.sql
security-fix-h4-audit-redact.sql
security-fix-h5-create-user-rpc.sql → -h5-create-user-rpc-v2.sql
security-fix-h6-impersonate-audit.sql
security-fix-m1-employees-view.sql
security-fix-m3-blacklist-permission.sql
security-fix-m4-unique-employee-id.sql
security-fix-storage.sql
security-fix-batch-2026-05-26.sql → -part2.sql
```

### 7️⃣ Leave
```
leave-types.sql → leave.sql
leave-approver.sql → leave-approval-chain.sql
leave-scope.sql → leave-security.sql → leave-anti-tamper.sql → leave-chain-rls-expand.sql
```

### 8️⃣ Holiday Swap
```
calendar-swap.sql · thai-holidays-2569.sql
holiday-swap-requests.sql → holiday-swap-per-employee.sql → holiday-swap-mar-deadline.sql
```

### 9️⃣ Work Schedule
```
work-schedule.sql → schedule-custom-shift.sql → shifts-half-hour.sql
fix-schedule-rls-perf.sql
cross-branch-borrow.sql → borrow-auto-approve.sql · cross-branch-roster.sql
```

### 🔟 Recruit + Announcements
```
recruit.sql · blacklist.sql
announcements.sql → announcement-reads.sql → announcement-doc-number.sql
photos-and-storage.sql
```

### 1️⃣1️⃣ Uniform (chain เต็ม — ดู UNIFORM-STOCK-MIGRATION-CHECKLIST.md)
```
uniform.sql → uniform-schedule.sql → uniform-applicant-link.sql
uniform-request-type.sql → uniform-self-rls.sql
uniform-stock-trigger.sql → uniform-stock-movements.sql
uniform-modern-inventory.sql → uniform-issues-snapshot.sql
uniform-stock-trigger-fix.sql → uniform-request-brand.sql → remove-kb-brand.sql
```

### 1️⃣2️⃣ Org Chart + Perf (รันท้ายสุด)
```
user-profiles-public-read.sql · org-chart-rpc.sql · autofill-managed-branches.sql
fix-employees-rls-perf.sql · fix-employees-view-perf.sql · fix-is-hr-session-cache.sql
```

---

## 🗑️ ไฟล์ที่ Superseded / Deprecated

| ไฟล์ | ถูกทับโดย | สถานะ |
|------|----------|-------|
| `role-matrix.sql` (role_permission_matrix) | `permissions-v1.sql` (roles/permissions/role_permissions) | legacy — ยังมี table แต่ไม่ใช่ source หลัก |
| `security-fix-h5-create-user-rpc.sql` | `-v2.sql` | ใช้ v2 |
| `employee-accounts.sql` | `-fix4.sql` (สะสม) | รันครบลำดับ |
| `reset-password-default-natid.sql` (NID เป็น default pwd) | `security-fix-c2` (random pwd) | logic เก่าถูกแทน |

> ไฟล์เหล่านี้**ยังต้องรัน**ตามลำดับ (เพราะ idempotent + ภายหลังทับ) — อย่าลบทิ้งจนกว่าจะมี baseline.sql

---

## 🔍 ตรวจสอบ state หลัง setup

รัน `supabase-smoke-test.sql` → ดูว่าทุก assertion PASS

---

## 💡 ข้อเสนอ Governance (ไปข้างหน้า)

สำหรับ migration ใหม่ตั้งแต่นี้ — ตั้งชื่อแบบ timestamp prefix:
```
20260527_143000_add_feature.sql
```
→ เรียงลำดับอัตโนมัติ + รู้ว่าอันไหนใหม่กว่า

และเมื่อมี baseline.sql แล้ว → migration เก่าทั้งหมดย้ายไป `archive/` ได้
