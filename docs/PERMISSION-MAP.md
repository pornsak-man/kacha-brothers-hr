# Permission Map — หน้า × Key × Wired Status

> mapping ระหว่าง 27 หน้า/ฟีเจอร์ กับ permission keys + สถานะการ wire
> ใช้ตรวจว่าแต่ละหน้าคุมสิทธิ์ครบไหม และคุมที่ชั้นไหน

## 🎯 3 ชั้นของการคุมสิทธิ์

| ชั้น | กลไก | ครอบคลุม |
|-----|------|----------|
| 🟢 **RLS (data)** | `is_hr_or_admin()` / `can_view_employee()` ใน policy | ทุก table — boundary จริง |
| 🟡 **Menu (sidebar)** | `data-perm` + `canSeeMenu()` | 20 เมนู (Phase B) |
| 🟠 **Action buttons** | `requirePermission()` / `requireHR()` | บางปุ่ม |

> **สำคัญ:** RLS คือ security boundary จริง — menu/button เป็น UX layer
> ต่อให้เมนูโผล่หรือปุ่มกดได้ ถ้า RLS บล็อก → ข้อมูลไม่หลุด

---

## 📋 Mapping ครบ 27 หน้า

| หน้า (router) | Permission key | เมนู wired (Phase B) | Action wired |
|--------------|----------------|:---:|:---:|
| dashboard | — (สาธารณะ) | — | — |
| announcements | — (ทุกคนเห็นประกาศ) | — | `announcement.manage` (จัดการ) |
| employees | `employee.view_list` | ✅ | `employee.delete`, `bulk_import` ✅ · อื่นๆ `requireHR` |
| recruit | `applicant.view` | ✅ | `requireHR` |
| evaluations | `evaluation.view` | ✅ | `requireHR` |
| leave | — (ทุกคนยื่นลา) | — | `leave.manage_types` ✅ |
| schedule | `schedule.view` | ✅ | `requireHR`/role check |
| schedule-monthly | (ตาม schedule) | — | — |
| leave-calendar | `leave_calendar.view` | ✅ | — |
| borrow-requests | `borrow.view` 🆕 | ✅ | role check (BM/AM) |
| calendar | — (ดูวันหยุดได้ทุกคน) | — | `holiday.manage` (แก้) |
| uniform | `uniform.view` | ✅ | `requireHR` |
| my-uniform | — (มี employee_id) | (logic แยก) | self-service |
| branch-managers | `branch.assign_managers` | ✅ | `requireHR` |
| branches | `branch.view` | ✅ | `requireHR` |
| positions | `position.view` | ✅ | `requireHR` |
| departments | `department.view` | ✅ | `requireHR` |
| salary-adjust | `salary.adjust` | ✅ | `salary.adjust` ✅ |
| loans | `loan.view` | ✅ | `requireHR` |
| advances | `advance.view` | ✅ | `requireHR` |
| allowance | `allowance.view` | ✅ | `requireHR` |
| reports | `report.view` 🆕 | ✅ | `system.full_backup` ✅ |
| sso | `sso.view` | ✅ | `requireHR` |
| blacklist | `blacklist.manage` | ✅ | `blacklist.manage` ✅ |
| audit | `system.view_audit` | ✅ | `system.view_audit` ✅ |
| user-roles | `user.view_accounts` | ✅ | `user.set_role`, `create_account`, `bulk_create` ✅ |
| settings | `system.edit_company` | ✅ | `system.edit_company` ✅ |

🆕 = เพิ่มใหม่ใน v3 (ต้องรัน `permissions-v3-borrow-report.sql`)

---

## ✅ สรุปสถานะ

### Menu gating (Phase B) — **ครบ 20/20 เมนูที่ควร gate**
- ทุก nav-item มี `data-perm` → `canSeeMenu()` คุม
- group auto-hide ถ้าไม่มี item แสดง
- admin เห็นทุกเมนูเสมอ (กัน lockout)

### Action buttons — **wire บางส่วน (~13 จุด)**

**Wire requirePermission แล้ว:**
- `employee.delete`, `employee.bulk_import`
- `salary.adjust`, `system.full_backup`
- `blacklist.manage`, `system.view_audit`
- `leave.manage_types`, `permission.edit_matrix`
- `user.set_role`, `user.create_account`, `user.bulk_create`
- `system.edit_company`

**ยังใช้ `requireHR()` (action ที่เหลือ):**
- uniform: เพิ่ม/แก้ item, รับเข้า stock, จัดชุด
- sso: บันทึกแจ้งเข้า/ออก
- loan/advance/allowance: เพิ่ม/แก้/ลบ
- recruit: จัดการผู้สมัคร
- branches/departments/positions: เพิ่ม/แก้/ลบ

---

## ⚠️ ทำไมยังไม่ wire action ที่เหลือทั้งหมด (Phase C)

มี **trade-off ด้าน security** ที่ตั้งใจ:

`requirePermission()` → `hasPermission()` เป็น **fail-closed** (Security fix M5):
- ถ้า matrix RPC (`user_permissions_list`) **fail** → return false (ยกเว้น safety locks)
- เจตนา: กัน broad access โดยไม่ตั้งใจถ้า RPC ล้ม

**ผลถ้าเปลี่ยน `requireHR` → `requirePermission` หว่านทุกจุด:**
- ปกติ (matrix โหลด) → ดี admin คุมได้
- แต่ถ้า matrix RPC fail ชั่วคราว → **block HR ทำงานทุกอย่าง** (เพราะ fail-closed)

`requireHR()` ปลอดภัยกว่าตอน matrix fail (เช็ค role ตรงๆ ไม่พึ่ง RPC)

### 💡 คำแนะนำ: wire action แบบ incremental
เปลี่ยน `requireHR` → `requirePermission` **เฉพาะเมื่อ** ต้องการให้ role อื่น (ไม่ใช่ HR) ทำ action นั้น เช่น:
- อยากให้ branch_manager เพิ่ม uniform item เอง → wire `uniform.manage`
- อยากให้ area_manager บันทึก sso → wire `sso.manage`

ไม่ใช่ rewrite ทั้งหมดพร้อมกัน (เสี่ยง regression + block HR ตอน RPC fail)

---

## 🔧 วิธีตรวจสอบใน UI

หน้า "ผู้ใช้และสิทธิ์" → ตารางสิทธิ์ → มี **auto-detect banner** ที่สแกน `hasPermission()`/`requirePermission()` ใน code → ถ้าเจอ key ที่ยังไม่ seed → เตือน

> Auto-detect จับได้แค่ key ที่ code เรียก `hasPermission()` — **จับไม่ได้** ฟีเจอร์ที่ guard ด้วย `requireHR()` (เพราะไม่ใช่ permission key) → ใช้ตาราง mapping นี้ประกอบ

---

## 📈 Roadmap (ถ้าต้องการ control เต็มที่)

1. ✅ **Phase A** — เพิ่ม keys borrow/report (ครบ 27 หน้า)
2. ✅ **Phase B** — เมนู sidebar อ่าน matrix
3. ⏸️ **Phase C** — wire action buttons (incremental ตามต้องการ — ไม่ rush)
4. 🔮 **อนาคต** — ปรับ `hasPermission` ให้มี "soft mode" (fallback legacy เมื่อ RPC fail) ถ้าต้องการ wire action ครบโดยไม่เสี่ยง block HR
