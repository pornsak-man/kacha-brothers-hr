# Disaster Recovery & Backup — คู่มือ

> ระบบ HR เก็บข้อมูล sensitive (เงินเดือน, ปชช, ประวัติ) — backup เป็นเรื่องจำเป็น
> เอกสารนี้: backup strategy + export script + restore testing

## 🎯 สรุปสั้น — ต้องทำอะไรบ้าง

| รายการ | ความถี่ | วิธี |
|--------|---------|------|
| Supabase auto-backup | อัตโนมัติ | ตรวจว่าเปิด (ขึ้นกับ tier) |
| Export critical tables | สัปดาห์ละครั้ง | `supabase-export-critical.sql` หรือ CLI |
| Restore test | เดือนละครั้ง | restore ลง project ทดสอบ |
| Schema baseline | เมื่อ schema เปลี่ยนใหญ่ | `supabase db dump` |

---

## 1️⃣ Supabase Built-in Backup (ตรวจก่อน)

ไปที่ **Supabase Dashboard → Database → Backups**

| Tier | Backup ที่ได้ |
|------|--------------|
| **Free** | ❌ ไม่มี automated backup — **ต้อง manual export เอง** (สำคัญมาก!) |
| **Pro ($25/mo)** | ✅ Daily backup เก็บ 7 วัน |
| **Pro + PITR add-on** | ✅ Point-in-time recovery (กู้ได้ทุกวินาที) |

> ⚠️ ถ้าใช้ **Free tier** → ไม่มี safety net เลย → **ต้องทำ manual export ตามข้อ 2 สม่ำเสมอ**
>
> 💡 สำหรับระบบ HR จริงที่มีข้อมูลพนักงาน — แนะนำอย่างยิ่งให้อัพเป็น **Pro + PITR** (เงินเดือน/ปชช หายไม่ได้)

---

## 2️⃣ Export Critical Tables (Manual Backup)

### ทางเลือก A: Supabase CLI (ครบสุด — แนะนำ)
```bash
# ติดตั้ง CLI ครั้งเดียว
npm i -g supabase

# Full dump (schema + data)
supabase db dump \
  --db-url "postgresql://postgres:[PASSWORD]@db.xvulimfftkoiybvqdjqz.supabase.co:5432/postgres" \
  -f "backup-$(date +%Y%m%d).sql"

# เฉพาะ data ของ critical tables
supabase db dump --data-only \
  --db-url "..." \
  -f "data-backup-$(date +%Y%m%d).sql"
```

### ทางเลือก B: SQL Editor → JSON export (เร็ว, ไม่ต้องติดตั้ง)
รัน `supabase-export-critical.sql` → copy ผลลัพธ์ JSON → เซฟเป็นไฟล์

### ทางเลือก C: Dashboard → Table Editor → Export CSV
แต่ละตาราง → ปุ่ม Export → CSV (ช้า, ทำทีละตาราง)

---

## 3️⃣ ตารางที่ต้อง Backup (จัดลำดับความสำคัญ)

| Priority | ตาราง | เหตุผล |
|----------|-------|--------|
| 🔴 Critical | `employees` | ข้อมูลพนักงานหลัก — สร้างใหม่ยากสุด |
| 🔴 Critical | `salary_history` | ประวัติเงินเดือน — ใช้กฎหมาย/ภาษี |
| 🔴 Critical | `user_profiles` | สิทธิ์การเข้าถึง |
| 🟠 High | `leave_requests`, `holiday_swap_requests` | ประวัติการลา |
| 🟠 High | `loans`, `advances`, `allowances` | ภาระการเงิน |
| 🟠 High | `evaluations` | ประเมินผล |
| 🟡 Medium | `schedule_weeks`, `schedule_entries` | ตารางงาน |
| 🟡 Medium | `uniform_*` | stock + ประวัติจัดชุด |
| 🟡 Medium | `audit_log` | หลักฐานการเปลี่ยนแปลง |
| 🟢 Low | `roles`, `permissions`, `role_permissions` | re-create จาก migration ได้ |
| 🟢 Low | `branches`, `departments`, `position_levels` | master data — re-seed ได้ |

---

## 4️⃣ Restore Testing (เดือนละครั้ง)

**ทำไมต้อง test:** backup ที่ restore ไม่ได้ = ไม่มี backup

```
1. สร้าง Supabase project ทดสอบ (free tier ใหม่)
2. รัน schema-baseline.sql (หรือ supabase-schema.sql + migrations)
3. Import data backup ล่าสุด
4. ตรวจ: รัน supabase-smoke-test.sql → PASS?
5. ตรวจ: นับ row เทียบกับ production
6. ลบ project ทดสอบ
```

✅ ถ้า restore สำเร็จ + smoke test PASS → backup ใช้ได้จริง

---

## 5️⃣ Sensitive Data Handling

⚠️ backup มี ปชช/เงินเดือน/bank → **เก็บอย่างปลอดภัย**

| Do | Don't |
|----|-------|
| เก็บใน encrypted drive | ❌ อัพขึ้น public cloud/GitHub |
| จำกัดคนเข้าถึง (HR/admin) | ❌ ส่งทาง email/chat |
| ตั้ง retention (ลบ backup เก่า > 1 ปี) | ❌ เก็บไว้ตลอดไม่ลบ |

> 🔒 ไฟล์ backup ห้าม commit เข้า git — เพิ่ม `*.backup.sql`, `backup-*.sql`, `data-*.sql` ใน `.gitignore`

---

## 6️⃣ Recovery Scenarios

| สถานการณ์ | วิธีกู้ |
|----------|--------|
| ลบ row ผิด (1-2 rows) | `audit_log` มี old value → manual restore |
| ลบ/แก้ผิดเยอะ (table) | PITR (Pro) → กู้ถึงเวลาก่อนพัง / หรือ restore จาก export |
| Project พังทั้งหมด | สร้าง project ใหม่ → baseline + data import |
| Migration ทำพัง | rollback script (ดูใน migration file นั้นๆ) |

---

## 📋 Checklist รายสัปดาห์

- [ ] รัน `supabase-export-critical.sql` → เซฟไฟล์ลง encrypted drive
- [ ] ตรวจ Dashboard → Backups ว่า auto-backup ทำงาน (Pro)
- [ ] (เดือนละครั้ง) Restore test ลง project ทดสอบ
- [ ] (เดือนละครั้ง) ลบ backup เก่ากว่า retention
