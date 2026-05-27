-- ═══════════════════════════════════════════════════════════
-- KACHA BROTHERS HR — Auto-deduct uniform stock (DB trigger)
--
-- ปัญหาเดิม (frontend-based deduction):
--   - Race condition: 2 HR กดพร้อมกัน → ตัด stock ทับกัน → stock ผิด
--   - ไม่ atomic: insert issue success แต่ adjust fail → stock ไม่ตัด
--   - Bypass ได้: เรียก client.from('uniform_issues').insert() ตรง → stock ไม่ตัด
--   - ไม่ check ก่อนตัด: max(0, current + delta) → ตัดเกิน stock ก็ผ่าน
--   - UPDATE qty/item_id ไม่ปรับ stock — เปลี่ยน qty 1→5 → stock ไม่ตัดเพิ่ม
--
-- แก้:
--   - Trigger BEFORE INSERT/UPDATE/DELETE บน uniform_issues
--   - ใช้ FOR UPDATE lock → atomic ป้องกัน race
--   - Check stock_qty >= qty → ไม่งั้น RAISE EXCEPTION (rollback transaction)
--   - UPDATE: คืน OLD stock + ตัด NEW stock (handle เปลี่ยน item/qty)
--   - DELETE: คืน stock
--
-- รันใน Supabase SQL Editor (idempotent)
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.uniform_issues_stock_trigger()
RETURNS TRIGGER
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_stock INTEGER;
  v_name  TEXT;
  v_size  TEXT;
BEGIN
  -- ════════════════════════════════════════════════════
  -- INSERT: ตัด stock (atomic + check sufficient)
  -- ════════════════════════════════════════════════════
  IF TG_OP = 'INSERT' THEN
    IF NEW.item_id IS NOT NULL AND COALESCE(NEW.qty, 0) > 0 THEN
      -- LOCK row + read stock
      SELECT stock_qty, name, size
        INTO v_stock, v_name, v_size
      FROM public.uniform_items
      WHERE id = NEW.item_id
      FOR UPDATE;

      IF v_stock IS NULL THEN
        RAISE EXCEPTION 'ไม่พบรายการชุดในระบบ (item_id %)', NEW.item_id;
      END IF;

      IF v_stock < NEW.qty THEN
        RAISE EXCEPTION 'Stock ไม่พอ: % ขนาด % เหลือ % ชิ้น แต่ต้องการจัด % ชิ้น',
          v_name, COALESCE(v_size, '-'), v_stock, NEW.qty;
      END IF;

      UPDATE public.uniform_items
      SET stock_qty = stock_qty - NEW.qty,
          updated_at = now()
      WHERE id = NEW.item_id;
    END IF;
    RETURN NEW;
  END IF;

  -- ════════════════════════════════════════════════════
  -- UPDATE: ปรับ stock ตาม diff (เปลี่ยน item หรือ qty)
  -- ════════════════════════════════════════════════════
  IF TG_OP = 'UPDATE' THEN
    -- ไม่เปลี่ยน item หรือ qty → no-op (e.g. update note, unit_cost only)
    IF NEW.item_id IS NOT DISTINCT FROM OLD.item_id
       AND COALESCE(NEW.qty, 0) = COALESCE(OLD.qty, 0) THEN
      RETURN NEW;
    END IF;

    -- คืน stock ของ OLD ก่อน (ถ้ามี)
    IF OLD.item_id IS NOT NULL AND COALESCE(OLD.qty, 0) > 0 THEN
      UPDATE public.uniform_items
      SET stock_qty = stock_qty + OLD.qty,
          updated_at = now()
      WHERE id = OLD.item_id;
    END IF;

    -- ตัด stock ของ NEW (ถ้ามี) — ต้อง LOCK + check ใหม่
    IF NEW.item_id IS NOT NULL AND COALESCE(NEW.qty, 0) > 0 THEN
      SELECT stock_qty, name, size
        INTO v_stock, v_name, v_size
      FROM public.uniform_items
      WHERE id = NEW.item_id
      FOR UPDATE;

      IF v_stock IS NULL THEN
        RAISE EXCEPTION 'ไม่พบรายการชุดในระบบ (item_id %)', NEW.item_id;
      END IF;

      IF v_stock < NEW.qty THEN
        RAISE EXCEPTION 'Stock ไม่พอ: % ขนาด % เหลือ % ชิ้น แต่ต้องการจัด % ชิ้น',
          v_name, COALESCE(v_size, '-'), v_stock, NEW.qty;
      END IF;

      UPDATE public.uniform_items
      SET stock_qty = stock_qty - NEW.qty,
          updated_at = now()
      WHERE id = NEW.item_id;
    END IF;
    RETURN NEW;
  END IF;

  -- ════════════════════════════════════════════════════
  -- DELETE: คืน stock
  -- ════════════════════════════════════════════════════
  IF TG_OP = 'DELETE' THEN
    IF OLD.item_id IS NOT NULL AND COALESCE(OLD.qty, 0) > 0 THEN
      UPDATE public.uniform_items
      SET stock_qty = stock_qty + OLD.qty,
          updated_at = now()
      WHERE id = OLD.item_id;
    END IF;
    RETURN OLD;
  END IF;

  RETURN NULL;
END $$;

-- ── Trigger registration ──
DROP TRIGGER IF EXISTS trg_uniform_issues_stock ON public.uniform_issues;
CREATE TRIGGER trg_uniform_issues_stock
  BEFORE INSERT OR UPDATE OR DELETE ON public.uniform_issues
  FOR EACH ROW
  EXECUTE FUNCTION public.uniform_issues_stock_trigger();

NOTIFY pgrst, 'reload schema';

-- ── Verify ──
DO $$
DECLARE
  v_trigger_exists BOOLEAN;
  v_low_stock_count INT;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_uniform_issues_stock'
      AND tgrelid = 'public.uniform_issues'::regclass
  ) INTO v_trigger_exists;

  SELECT count(*) INTO v_low_stock_count
  FROM public.uniform_items WHERE stock_qty < 5;

  RAISE NOTICE '✅ Uniform stock trigger ติดตั้งแล้ว: %', v_trigger_exists;
  RAISE NOTICE '';
  RAISE NOTICE '   ฟังก์ชัน:';
  RAISE NOTICE '   - INSERT uniform_issues → atomic deduct stock + check sufficient';
  RAISE NOTICE '   - UPDATE qty/item_id  → คืน OLD stock + ตัด NEW stock';
  RAISE NOTICE '   - DELETE uniform_issues → คืน stock';
  RAISE NOTICE '';
  RAISE NOTICE '   ⚠ ข้อควรระวัง:';
  RAISE NOTICE '   - หลังรัน SQL นี้ frontend ต้อง update เพื่อไม่ตัด stock ซ้ำ';
  RAISE NOTICE '   - รายการที่ stock < 5: % รายการ (เช็คใน uniform_items)', v_low_stock_count;
END $$;
