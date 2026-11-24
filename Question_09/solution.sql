-- ============================================================================
-- ICT371 Advanced Database | Student: Hope Nsana (202402859)
-- Question 9: Farmer Cooperative Maize Deliveries (50 Marks)
-- Target Engine: PostgreSQL 18.6
-- Isolated Schema: q09_maize_coop
-- ============================================================================

DROP SCHEMA IF EXISTS q09_maize_coop CASCADE;
CREATE SCHEMA q09_maize_coop;
SET search_path TO q09_maize_coop, public;

-- ============================================================================
-- (a) Database and Seed Data [6 marks]
--     - NUMERIC(10,2) weight fields and NUMERIC(12,2) money fields
--     - Positive constraints on weight_kg, unit_rate, total_value; grade A/B/C
--     - Three farmers seeded here; six deliveries (covering grades A, B, C and
--       both paid/unpaid states, with FRM-003 having only paid deliveries) are
--       loaded immediately after installing the trigger in section (d).
-- ============================================================================

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id)
                               ON UPDATE CASCADE ON DELETE RESTRICT,
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(12,2) NOT NULL CHECK (unit_rate > 0),
    total_value  NUMERIC(12,2) NOT NULL CHECK (total_value > 0),
    delivered_on DATE          NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE          PRIMARY KEY,
    total_weight  NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (total_weight >= 0),
    total_value   NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (total_value >= 0)
);

-- Seed three farmers
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FRM-001', 'Chanda Mulenga'),
    ('FRM-002', 'Mutale Banda'),
    ('FRM-003', 'Bwalya Phiri');

SELECT * FROM farmers ORDER BY farmer_id;

-- ============================================================================
-- (b) Function: fn_maize_rate [6 marks]
--     Returns NUMERIC(10,2): K5.00 for 'A', K4.00 for 'B', K3.00 for 'C'.
--     Rejects NULL or any unsupported grade with RAISE EXCEPTION.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL. Expected A, B, or C.';
    END IF;

    CASE p_grade
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE
            RAISE EXCEPTION 'Unsupported maize grade "%". Allowed grades are A, B, or C.', p_grade;
    END CASE;
END;
$$;

-- Verify fn_maize_rate valid grades
SELECT
    fn_maize_rate('A') AS rate_grade_a,
    fn_maize_rate('B') AS rate_grade_b,
    fn_maize_rate('C') AS rate_grade_c;

-- Verify fn_maize_rate rejects NULL and unsupported grades
DO $$
BEGIN
    PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - NULL grade]: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Unsupported grade D]: %', SQLERRM;
END;
$$;

-- ============================================================================
-- (c) Procedure: pr_receive_delivery [8 marks]
--     Validates farmer existence and input arguments, then inserts only the
--     basic delivery fields; the BEFORE trigger supplies unit_rate & total_value.
-- ============================================================================

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     VARCHAR,
    p_weight    NUMERIC,
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_farmer_id IS NULL THEN
        RAISE EXCEPTION 'Farmer ID cannot be NULL.';
    END IF;

    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL.';
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Delivery weight must be greater than zero (got: %).', p_weight;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %. Farmer must be registered first.', p_farmer_id;
    END IF;

    -- Validate grade upfront (raises exception if unsupported)
    PERFORM fn_maize_rate(p_grade);

    -- Insert basic fields only; trigger calculates unit_rate and total_value
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, ROUND(p_weight, 2), p_date, FALSE);
END;
$$;

-- ============================================================================
-- (d) Trigger: trg_deliveries_pricing [8 marks]
--     BEFORE INSERT OR UPDATE row trigger on deliveries.
--     Rejects non-positive weight, calls fn_maize_rate(NEW.grade), and sets
--     NEW.unit_rate and NEW.total_value consistently for both procedure calls
--     and direct SQL INSERT/UPDATE statements.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_trg_deliveries_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight_kg must be positive (got: %).', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_trg_deliveries_pricing();

-- ----------------------------------------------------------------------------
-- Load the six seed deliveries for (a) AFTER installing the trigger:
--   * Covers all grades ('A', 'B', 'C') and both payment states (TRUE, FALSE)
--   * Demonstrates pr_receive_delivery AND direct SQL INSERTs
--   * Farmer 3 (FRM-003) has ONLY paid deliveries (0 unpaid) to verify (e)
-- ----------------------------------------------------------------------------

-- 1 & 2: Unpaid deliveries received through pr_receive_delivery
CALL pr_receive_delivery(1, 'A', 250.50, DATE '2026-05-18'); -- FRM-001, Grade A, unpaid (1252.50)
CALL pr_receive_delivery(2, 'A', 150.00, DATE '2026-05-18'); -- FRM-002, Grade A, unpaid (750.00)

-- 3: Direct SQL INSERT attempting to supply bogus unit_rate (999.00) & total_value (1.00)
--    Trigger overrides them to exact Grade C rate (3.00) and total_value (960.75)
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (2, 'C', 320.25, 999.00, 1.00, DATE '2026-05-20', FALSE);

-- 4, 5, 6: Direct SQL INSERTs for paid deliveries (trigger supplies unit_rate & total_value)
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'B', 180.00, DATE '2026-05-19', TRUE),  -- FRM-001, Grade B, paid (720.00)
    (3, 'B', 400.00, DATE '2026-05-18', TRUE),  -- FRM-003, Grade B, paid (1600.00)
    (3, 'C', 210.00, DATE '2026-05-20', TRUE);  -- FRM-003, Grade C, paid (630.00)

-- Inspect all six seeded deliveries (confirming consistent pricing & override of 999.00)
SELECT
    delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid
FROM deliveries
ORDER BY delivery_id;

-- Verify BEFORE UPDATE pricing enforcement (attempting bogus manual total_value on update)
BEGIN;
UPDATE deliveries
SET grade = 'B', weight_kg = 200.00, unit_rate = 777.00, total_value = 777.00
WHERE delivery_id = 2;

SELECT delivery_id, grade, weight_kg, unit_rate, total_value
FROM deliveries
WHERE delivery_id = 2;
ROLLBACK;

-- Verify procedure & trigger error handling (unknown farmer, non-positive weight, invalid grade)
DO $$
BEGIN
    CALL pr_receive_delivery(999, 'A', 100.00, DATE '2026-05-21');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Unknown farmer]: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (1, 'A', -25.00, DATE '2026-05-21', FALSE);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Non-positive weight]: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (1, 'D', 50.00, DATE '2026-05-21', FALSE);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Invalid grade on direct INSERT]: %', SQLERRM;
END;
$$;

-- ============================================================================
-- (e) View: v_farmer_amount_due [5 marks]
--     Shows each farmer's farmer_number, full_name, and total unpaid value.
--     Includes farmers with no unpaid deliveries (FRM-003 shown as 0.00).
-- ============================================================================

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value), 0.00)::NUMERIC(12,2) AS unpaid_amount_due
FROM farmers f
LEFT JOIN deliveries d
    ON d.farmer_id = f.farmer_id
   AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- ============================================================================
-- (f) Index: idx_deliveries_farmer_date [5 marks]
--     Composite B-tree index on (farmer_id, delivered_on) supporting queries
--     that fetch a specific farmer's deliveries between two dates.
-- ============================================================================

CREATE INDEX idx_deliveries_farmer_date
ON deliveries (farmer_id, delivered_on);

ANALYZE deliveries;

-- Matching range query for a single farmer's deliveries between two dates
SELECT
    delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
ORDER BY delivered_on;

-- Demonstrate index usage via EXPLAIN (disable seqscan briefly for 6-row table)
SET enable_seqscan = off;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT
    delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
ORDER BY delivered_on;

RESET enable_seqscan;

-- ============================================================================
-- (g) Scheduled Job: pr_refresh_purchases & Daily 01:30 Schedule [6 marks]
--     Stores p_day's purchased weight and value in daily_purchases.
--     Uses ON CONFLICT (purchase_date) DO UPDATE so reruns replace totals
--     rather than adding them again. Scheduled daily at 01:30 for yesterday.
-- ============================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Target purchase date (p_day) cannot be NULL.';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT
        p_day,
        COALESCE(SUM(weight_kg), 0.00)::NUMERIC(10,2),
        COALESCE(SUM(total_value), 0.00)::NUMERIC(12,2)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

-- First execution for 2026-05-18 (3 deliveries: 250.50 + 150.00 + 400.00 = 800.50 kg;
-- 1252.50 + 750.00 + 1600.00 = 3602.50 Kwacha)
CALL pr_refresh_purchases(DATE '2026-05-18');
SELECT * FROM daily_purchases WHERE purchase_date = DATE '2026-05-18';

-- Second execution for 2026-05-18 (proves totals are replaced, NOT doubled)
CALL pr_refresh_purchases(DATE '2026-05-18');
SELECT * FROM daily_purchases WHERE purchase_date = DATE '2026-05-18';

-- Refresh remaining seed dates plus a zero-delivery date (CURRENT_DATE - 1)
CALL pr_refresh_purchases(DATE '2026-05-19');
CALL pr_refresh_purchases(DATE '2026-05-20');
CALL pr_refresh_purchases(CURRENT_DATE - 1);

SELECT * FROM daily_purchases ORDER BY purchase_date;

-- Register daily 01:30 pg_cron job for the previous day (guarded for Windows PG 18)
DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        SELECT jobid INTO v_job_id
        FROM cron.job
        WHERE jobname = 'q09_daily_maize_purchases';

        IF v_job_id IS NOT NULL THEN
            PERFORM cron.unschedule(v_job_id);
        END IF;

        PERFORM cron.schedule(
            'q09_daily_maize_purchases',
            '30 1 * * *',
            $cron$CALL q09_maize_coop.pr_refresh_purchases(CURRENT_DATE - 1);$cron$
        );
        RAISE NOTICE 'Scheduled pg_cron job q09_daily_maize_purchases at 01:30 daily (30 1 * * *).';
    ELSE
        RAISE NOTICE 'pg_cron extension is not installed on this Windows PostgreSQL 18.6 server; schedule specification (30 1 * * * -> CALL q09_maize_coop.pr_refresh_purchases(CURRENT_DATE - 1)) verified via procedure execution above.';
    END IF;
END;
$$;
