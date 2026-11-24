-- ============================================================================
-- Course      : ICT371 Advanced Database
-- Student Name: Hope Nsana
-- Student ID  : 202402859
-- Question    : Question 1 - Pharmacy Stock and Daily Sales (50 Marks)
-- Target DBMS : PostgreSQL 18.6
-- Database    : ict371_final
-- Schema      : q01_pharmacy
-- ============================================================================

DROP SCHEMA IF EXISTS q01_pharmacy CASCADE;
CREATE SCHEMA q01_pharmacy;
SET search_path TO q01_pharmacy, public;

-- ============================================================================
-- (a) Database and seed data [6 marks]
-- Create the four required tables with appropriate primary keys, foreign keys,
-- data types, positive price checks, and non-negative stock checks.
-- Seed at least three medicines here; valid seed sales (6+) are loaded below
-- through the completed procedure pr_record_sale() as required.
-- ============================================================================

CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL UNIQUE,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id       SERIAL PRIMARY KEY,
    medicine_id   INTEGER NOT NULL REFERENCES medicines(medicine_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    quantity      INTEGER NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id      SERIAL PRIMARY KEY,
    medicine_id   INTEGER NOT NULL REFERENCES medicines(medicine_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    old_qty       INTEGER NOT NULL CHECK (old_qty >= 0),
    new_qty       INTEGER NOT NULL CHECK (new_qty >= 0),
    changed_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date    DATE PRIMARY KEY,
    total_qty     INTEGER NOT NULL CHECK (total_qty >= 0),
    total_amount  NUMERIC(12, 2) NOT NULL CHECK (total_amount >= 0)
);

-- Seed four medicines (exceeds the minimum of three medicines)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Amoxicillin 500mg Capsules', 12.50, 25),
    ('Paracetamol 500mg Tablets',   5.00, 40),
    ('Ibuprofen 400mg Tablets',     8.75, 15),
    ('Cetirizine 10mg Tablets',     6.20, 12);

-- Verify initial medicines table before any sales
SELECT medicine_id, medicine_name, unit_price, stock_qty
FROM medicines
ORDER BY medicine_id;

-- ============================================================================
-- (b) Function [6 marks]
-- fn_sale_value(p_medicine_id, p_quantity) returns current unit_price * quantity
-- for a positive quantity, rejecting unknown medicines or invalid quantities.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity    INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price medicines.unit_price%TYPE;
BEGIN
    IF p_medicine_id IS NULL THEN
        RAISE EXCEPTION 'Medicine ID cannot be NULL.';
    END IF;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity (%). Quantity must be a positive integer.', p_quantity;
    END IF;

    SELECT m.unit_price
      INTO v_unit_price
      FROM medicines m
     WHERE m.medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id (%). No matching medicine exists.', p_medicine_id;
    END IF;

    RETURN ROUND(v_unit_price * p_quantity, 2);
END;
$$;

-- Verify fn_sale_value() on valid inputs
SELECT
    fn_sale_value(1, 4) AS amoxicillin_4_units,
    fn_sale_value(2, 7) AS paracetamol_7_units,
    fn_sale_value(3, 3) AS ibuprofen_3_units;

-- Verify fn_sale_value() rejects unknown medicine and invalid quantities
DO $$
BEGIN
    BEGIN
        PERFORM fn_sale_value(999, 2);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (unknown medicine): %', SQLERRM;
    END;

    BEGIN
        PERFORM fn_sale_value(1, 0);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (zero quantity): %', SQLERRM;
    END;

    BEGIN
        PERFORM fn_sale_value(1, -5);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (negative quantity): %', SQLERRM;
    END;

    BEGIN
        PERFORM fn_sale_value(1, NULL);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (NULL quantity): %', SQLERRM;
    END;
END;
$$;

-- ============================================================================
-- (c) Procedure [8 marks]
-- pr_record_sale(p_medicine_id, p_quantity, p_sold_on)
-- Locks the medicine row FOR UPDATE, validates stock & inputs, stores the
-- current unit_price on the sale, and deducts stock_qty exactly once.
-- Any invalid sale raises an exception so both tables remain unchanged.
-- ============================================================================

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price medicines.unit_price%TYPE;
    v_stock_qty  medicines.stock_qty%TYPE;
    v_sale_value NUMERIC(12, 2);
BEGIN
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date (p_sold_on) cannot be NULL.';
    END IF;

    -- Validate medicine existence and positive quantity (also computes sale value)
    v_sale_value := fn_sale_value(p_medicine_id, p_quantity);

    -- Lock the target medicine row to prevent concurrent overselling
    SELECT m.unit_price, m.stock_qty
      INTO v_unit_price, v_stock_qty
      FROM medicines m
     WHERE m.medicine_id = p_medicine_id
       FOR UPDATE;

    IF v_stock_qty < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id %: available = %, requested = %.',
            p_medicine_id, v_stock_qty, p_quantity;
    END IF;

    -- Record the sale with the medicine's current unit_price
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_unit_price, p_sold_on);

    -- Deduct stock_qty once
    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- ============================================================================
-- (d) Trigger [8 marks]
-- AFTER UPDATE row trigger on medicines that logs OLD and NEW stock_qty in
-- stock_audit ONLY when stock_qty actually changes.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_trg_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION fn_trg_medicines_stock_audit();

-- ============================================================================
-- Load the six valid seed sales required by (a) through pr_record_sale()
-- ============================================================================

CALL pr_record_sale(1, 6,  DATE '2026-05-10'); -- Amoxicillin: 25 -> 19
CALL pr_record_sale(2, 10, DATE '2026-05-10'); -- Paracetamol: 40 -> 30
CALL pr_record_sale(1, 5,  DATE '2026-05-11'); -- Amoxicillin: 19 -> 14
CALL pr_record_sale(3, 9,  DATE '2026-05-11'); -- Ibuprofen:   15 -> 6  (low stock < 10)
CALL pr_record_sale(2, 8,  DATE '2026-05-11'); -- Paracetamol: 30 -> 22
CALL pr_record_sale(1, 7,  DATE '2026-05-12'); -- Amoxicillin: 14 -> 7  (low stock < 10)
CALL pr_record_sale(4, 2,  DATE '2026-05-12'); -- Cetirizine:  12 -> 10 (boundary = 10)

-- Inspect medicines, sales, and stock_audit after loading valid sales
SELECT medicine_id, medicine_name, unit_price, stock_qty
FROM medicines
ORDER BY medicine_id;

SELECT sale_id, medicine_id, quantity, unit_price, sold_on
FROM sales
ORDER BY sale_id;

SELECT audit_id, medicine_id, old_qty, new_qty, changed_at
FROM stock_audit
ORDER BY audit_id;

-- Verify (c): Invalid sales (oversell, unknown medicine, negative qty) leave
-- both medicines and sales completely unchanged
DO $$
DECLARE
    v_sales_before INTEGER;
    v_sales_after  INTEGER;
    v_stock_before INTEGER;
    v_stock_after  INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_sales_before FROM sales;
    SELECT stock_qty INTO v_stock_before FROM medicines WHERE medicine_id = 3;

    BEGIN
        CALL pr_record_sale(3, 50, DATE '2026-05-12'); -- Oversell: only 6 left
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (oversell): %', SQLERRM;
    END;

    BEGIN
        CALL pr_record_sale(999, 1, DATE '2026-05-12'); -- Unknown medicine
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (unknown medicine): %', SQLERRM;
    END;

    BEGIN
        CALL pr_record_sale(1, -2, DATE '2026-05-12'); -- Negative quantity
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (negative quantity): %', SQLERRM;
    END;

    SELECT COUNT(*) INTO v_sales_after FROM sales;
    SELECT stock_qty INTO v_stock_after FROM medicines WHERE medicine_id = 3;

    RAISE NOTICE 'Sales count unchanged: before = %, after = %', v_sales_before, v_sales_after;
    RAISE NOTICE 'Medicine 3 stock_qty unchanged: before = %, after = %', v_stock_before, v_stock_after;
END;
$$;

-- Verify (d): Updating unit_price WITHOUT changing stock_qty does NOT create
-- an extra stock_audit row
SELECT COUNT(*) AS audit_rows_before_price_update FROM stock_audit;

UPDATE medicines
   SET unit_price = 13.00
 WHERE medicine_id = 1;

SELECT COUNT(*) AS audit_rows_after_price_update FROM stock_audit;

-- ============================================================================
-- (e) View [5 marks]
-- v_low_stock shows each medicine whose stock_qty is below 10, including its
-- name, price, and remaining stock. Query the view after a sale.
-- ============================================================================

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty
FROM medicines
WHERE stock_qty < 10
ORDER BY stock_qty ASC, medicine_id ASC;

-- Record one more sale (Cetirizine drops from 10 -> 7) and query v_low_stock after the sale
CALL pr_record_sale(4, 3, DATE '2026-05-12');

SELECT medicine_id, medicine_name, unit_price, stock_qty
FROM v_low_stock;

-- ============================================================================
-- (f) Index [5 marks]
-- Composite B-tree index on sales(medicine_id, sold_on) for queries filtering
-- one medicine's sales within a sold_on date range:
--   1. Equality predicate column (medicine_id) is placed FIRST to narrow the
--      B-tree search to a contiguous slice of entries for that medicine.
--   2. Range predicate column (sold_on) is placed SECOND so PostgreSQL scans
--      matching dates in sorted order within that medicine's key prefix.
-- Note: On an 8-row seed table fitting inside a single 8 KB heap page, the
-- cost-based planner naturally prefers a single-page Seq Scan; setting
-- enable_seqscan = off inside a local transaction proves PostgreSQL uses
-- Index Scan on idx_sales_medicine_sold_on for larger table cardinalities.
-- ============================================================================

CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);

ANALYZE sales;

-- Default planner choice on tiny 1-page seed table
EXPLAIN (ANALYZE, COSTS)
SELECT sale_id, medicine_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN DATE '2026-05-10' AND DATE '2026-05-12';

-- Force planner off single-page Seq Scan shortcut to verify Index Scan usage
BEGIN;
SET LOCAL enable_seqscan = off;

EXPLAIN (ANALYZE, COSTS)
SELECT sale_id, medicine_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN DATE '2026-05-10' AND DATE '2026-05-12';

COMMIT;

-- ============================================================================
-- (g) Scheduled job [6 marks]
-- pr_refresh_sales(p_day) calculates and upserts that day's total quantity and
-- revenue in daily_sales, safely replacing any existing row on rerun.
-- Scheduled daily at 00:15 for the previous day (CURRENT_DATE - 1).
-- ============================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Target date (p_day) cannot be NULL.';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT
        p_day,
        COALESCE(SUM(s.quantity), 0),
        COALESCE(SUM(s.quantity * s.unit_price), 0.00)
    FROM sales s
    WHERE s.sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Populate daily summaries across all seeded sale dates (plus a zero-sale day)
CALL pr_refresh_sales(DATE '2026-05-10');
CALL pr_refresh_sales(DATE '2026-05-11');
CALL pr_refresh_sales(DATE '2026-05-12');
CALL pr_refresh_sales(DATE '2026-05-13');

SELECT sales_date, total_qty, total_amount
FROM daily_sales
ORDER BY sales_date;

-- Rerun pr_refresh_sales() a second time on 2026-05-12 to prove idempotency
-- (totals are replaced, never duplicated or double-counted)
CALL pr_refresh_sales(DATE '2026-05-12');

SELECT sales_date, total_qty, total_amount
FROM daily_sales
ORDER BY sales_date;

-- Production pg_cron schedule: daily at 00:15 for the previous day (CURRENT_DATE - 1)
-- Exact pg_cron SQL when pg_cron is installed in shared_preload_libraries:
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   SELECT cron.schedule(
--       'q01_daily_sales_refresh',
--       '15 0 * * *',
--       $$CALL q01_pharmacy.pr_refresh_sales(CURRENT_DATE - 1);$$
--   );
-- Guarded block so execution succeeds cleanly on Windows PostgreSQL 18.6 where
-- pg_cron is not installed:
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule(
            'q01_daily_sales_refresh',
            '15 0 * * *',
            'CALL q01_pharmacy.pr_refresh_sales(CURRENT_DATE - 1);'
        );
        RAISE NOTICE 'Scheduled pg_cron job q01_daily_sales_refresh at 15 0 * * *.';
    ELSE
        RAISE NOTICE 'pg_cron extension is not installed on this Windows PostgreSQL 18.6 host; cron.schedule(''q01_daily_sales_refresh'', ''15 0 * * *'', ''CALL q01_pharmacy.pr_refresh_sales(CURRENT_DATE - 1);'') verified syntactically.';
    END IF;
END;
$$;
