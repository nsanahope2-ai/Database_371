-- ============================================================================
-- Course      : ICT371 Advanced Database
-- Student Name: Hope Nsana
-- Student ID  : 202402859
-- Question    : Question 2 - University Fee Payments (50 Marks)
-- Target DBMS : PostgreSQL 18.6
-- Database    : ict371_final
-- Schema      : q02_university_fees
-- ============================================================================

DROP SCHEMA IF EXISTS q02_university_fees CASCADE;
CREATE SCHEMA q02_university_fees;
SET search_path TO q02_university_fees, public;

-- ============================================================================
-- (a) Database and seed data [6 marks]
-- Create the four required tables with constraints (credit balances disallowed,
-- positive payment amounts, unique student_number).
-- Seed three students with distinct fee_due amounts; six valid payments are
-- recorded below once the trigger and payment procedure are defined so every
-- payment is audited automatically while one student (Student 3) has no payments.
-- ============================================================================

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL,
    fee_due        NUMERIC(12, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id     SERIAL PRIMARY KEY,
    student_id     INTEGER NOT NULL REFERENCES students(student_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    amount         NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on        DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id       SERIAL PRIMARY KEY,
    payment_id     INTEGER NOT NULL REFERENCES payments(payment_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    student_id     INTEGER NOT NULL REFERENCES students(student_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    amount         NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    logged_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL CHECK (payment_count >= 0),
    total_amount    NUMERIC(12, 2) NOT NULL CHECK (total_amount >= 0)
);

-- Seed three students with three distinct fee balances
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU-2024-001', 'Mutale Banda',   5000.00),
    ('STU-2024-002', 'Thandiwe Phiri', 4500.00),
    ('STU-2024-003', 'Kelvin Mwansa',  6000.00);

SELECT student_id, student_number, full_name, fee_due
FROM students
ORDER BY student_id;

-- ============================================================================
-- (b) Function [6 marks]
-- fn_fee_balance(p_student_id) returns fee_due minus total payments.
-- Returns the full fee when no payments exist, and rejects unknown/NULL student.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due    students.fee_due%TYPE;
    v_total_paid NUMERIC(12, 2);
BEGIN
    IF p_student_id IS NULL THEN
        RAISE EXCEPTION 'Student ID cannot be NULL.';
    END IF;

    SELECT s.fee_due
      INTO v_fee_due
      FROM students s
     WHERE s.student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id (%). No matching student exists.', p_student_id;
    END IF;

    SELECT COALESCE(SUM(p.amount), 0.00)
      INTO v_total_paid
      FROM payments p
     WHERE p.student_id = p_student_id;

    RETURN ROUND(v_fee_due - v_total_paid, 2);
END;
$$;

-- Verify fn_fee_balance() before any payments exist (returns full fee_due)
SELECT
    student_id,
    student_number,
    full_name,
    fee_due,
    fn_fee_balance(student_id) AS initial_balance
FROM students
ORDER BY student_id;

-- Verify fn_fee_balance() rejects unknown and NULL student_id
DO $$
BEGIN
    BEGIN
        PERFORM fn_fee_balance(999);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (unknown student): %', SQLERRM;
    END;

    BEGIN
        PERFORM fn_fee_balance(NULL);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (NULL student): %', SQLERRM;
    END;
END;
$$;

-- ============================================================================
-- (c) Procedure [8 marks]
-- pr_receive_payment(p_student_id, p_amount, p_paid_on)
-- Rejects NULL/zero/negative amounts, NULL date, unknown student, and any
-- payment exceeding the student's current outstanding balance (no credit
-- balances allowed). Inserts valid payment WITHOUT modifying students.fee_due
-- and WITHOUT inserting into payment_audit (handled strictly by the trigger).
-- ============================================================================

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC(12, 2),
    p_paid_on    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_locked_id   students.student_id%TYPE;
    v_outstanding NUMERIC(12, 2);
BEGIN
    IF p_student_id IS NULL THEN
        RAISE EXCEPTION 'Student ID cannot be NULL.';
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount (%). Amount must be strictly positive.', p_amount;
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date (p_paid_on) cannot be NULL.';
    END IF;

    -- Lock the student row to serialize concurrent fee payments for the same student
    SELECT s.student_id
      INTO v_locked_id
      FROM students s
     WHERE s.student_id = p_student_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id (%). Cannot record payment.', p_student_id;
    END IF;

    v_outstanding := fn_fee_balance(p_student_id);

    IF p_amount > v_outstanding THEN
        RAISE EXCEPTION 'Overpayment rejected for student_id %: outstanding balance = %, attempted payment = %. Credit balances are not allowed.',
            p_student_id, v_outstanding, p_amount;
    END IF;

    -- Insert valid payment; students.fee_due is untouched and trigger writes audit row
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, ROUND(p_amount, 2), p_paid_on);
END;
$$;

-- ============================================================================
-- (d) Trigger [8 marks]
-- AFTER INSERT row trigger on payments that automatically writes payment_id,
-- student_id, amount, and timestamp to payment_audit.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_trg_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_trg_payments_audit();

-- ============================================================================
-- Load the six seed payments required by (a) via pr_receive_payment()
-- Student 1 (fee_due 5000.00): 4 payments totaling 5000.00 -> balance 0.00 (settled)
-- Student 2 (fee_due 4500.00): 2 payments totaling 2000.00 -> balance 2500.00 (partial)
-- Student 3 (fee_due 6000.00): 0 payments                  -> balance 6000.00 (unpaid)
-- ============================================================================

CALL pr_receive_payment(1, 1500.00, DATE '2026-05-10');
CALL pr_receive_payment(2, 1250.00, DATE '2026-05-10');
CALL pr_receive_payment(1, 1200.00, DATE '2026-05-11');
CALL pr_receive_payment(2,  750.00, DATE '2026-05-11');
CALL pr_receive_payment(1, 1300.00, DATE '2026-05-12');
CALL pr_receive_payment(1, 1000.00, DATE '2026-05-12');

-- Inspect students (fee_due unchanged!), payments, balances, and payment_audit
SELECT
    s.student_id,
    s.student_number,
    s.full_name,
    s.fee_due,
    fn_fee_balance(s.student_id) AS current_balance
FROM students s
ORDER BY s.student_id;

SELECT payment_id, student_id, amount, paid_on
FROM payments
ORDER BY payment_id;

SELECT audit_id, payment_id, student_id, amount, logged_at
FROM payment_audit
ORDER BY audit_id;

-- Verify (c): Zero, negative, NULL, unknown student, and overpayment attempts
-- are rejected and leave payments, payment_audit, and fee_due unchanged
DO $$
DECLARE
    v_payments_before INTEGER;
    v_payments_after  INTEGER;
    v_audit_before    INTEGER;
    v_audit_after     INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_payments_before FROM payments;
    SELECT COUNT(*) INTO v_audit_before FROM payment_audit;

    BEGIN
        CALL pr_receive_payment(2, 0.00, DATE '2026-05-12'); -- Zero amount
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (zero amount): %', SQLERRM;
    END;

    BEGIN
        CALL pr_receive_payment(2, -250.00, DATE '2026-05-12'); -- Negative amount
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (negative amount): %', SQLERRM;
    END;

    BEGIN
        CALL pr_receive_payment(2, NULL, DATE '2026-05-12'); -- NULL amount
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (NULL amount): %', SQLERRM;
    END;

    BEGIN
        CALL pr_receive_payment(2, 3000.00, DATE '2026-05-12'); -- Exceeds 2500.00 balance
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (overpayment on partial balance): %', SQLERRM;
    END;

    BEGIN
        CALL pr_receive_payment(1, 1.00, DATE '2026-05-12'); -- Exceeds 0.00 settled balance
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (overpayment on settled student): %', SQLERRM;
    END;

    BEGIN
        CALL pr_receive_payment(999, 100.00, DATE '2026-05-12'); -- Unknown student
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Expected rejection (unknown student): %', SQLERRM;
    END;

    SELECT COUNT(*) INTO v_payments_after FROM payments;
    SELECT COUNT(*) INTO v_audit_after FROM payment_audit;

    RAISE NOTICE 'Payments count unchanged: before = %, after = %', v_payments_before, v_payments_after;
    RAISE NOTICE 'Audit count unchanged   : before = %, after = %', v_audit_before, v_audit_after;
END;
$$;

-- ============================================================================
-- (e) View [5 marks]
-- v_fee_balances shows student_number, full_name, and outstanding_balance for
-- students who still owe fees (> 0). Fully settled students (Student 1) are
-- excluded.
-- ============================================================================

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    (s.fee_due - COALESCE(SUM(p.amount), 0.00))::NUMERIC(12, 2) AS outstanding_balance
FROM students s
LEFT JOIN payments p
       ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING (s.fee_due - COALESCE(SUM(p.amount), 0.00)) > 0
ORDER BY s.student_id;

-- Query v_fee_balances: Student 1 (balance 0.00) is excluded; Students 2 & 3 appear
SELECT student_number, full_name, outstanding_balance
FROM v_fee_balances;

-- ============================================================================
-- (f) Index [5 marks]
-- Composite B-tree index on payments(student_id, paid_on) for queries filtering
-- payments by student_id and a paid_on date range:
--   1. Equality column (student_id) comes FIRST so PostgreSQL seeks directly to
--      that student's index partition.
--   2. Range column (paid_on) comes SECOND so date-range bounds are scanned
--      contiguously in chronological order within that student_id prefix.
-- ============================================================================

CREATE INDEX idx_payments_student_paid_on
    ON payments (student_id, paid_on);

ANALYZE payments;

-- Default planner plan on small 6-row single-page table
EXPLAIN (ANALYZE, COSTS)
SELECT payment_id, student_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-05-10' AND DATE '2026-05-12';

-- Demonstrate Index Scan via idx_payments_student_paid_on when single-page Seq Scan shortcut is disabled
BEGIN;
SET LOCAL enable_seqscan = off;

EXPLAIN (ANALYZE, COSTS)
SELECT payment_id, student_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-05-10' AND DATE '2026-05-12';

COMMIT;

-- ============================================================================
-- (g) Scheduled job [6 marks]
-- pr_refresh_collections(p_day) stores payment_count and total_amount for that
-- date in daily_collections, replacing any existing summary row when rerun.
-- Scheduled daily at 01:00 for the previous day (CURRENT_DATE - 1).
-- ============================================================================

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Target collection date (p_day) cannot be NULL.';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT
        p_day,
        COUNT(p.payment_id)::INTEGER,
        COALESCE(SUM(p.amount), 0.00)
    FROM payments p
    WHERE p.paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;
END;
$$;

-- Run pr_refresh_collections() across all seeded payment dates (plus an empty date)
CALL pr_refresh_collections(DATE '2026-05-10');
CALL pr_refresh_collections(DATE '2026-05-11');
CALL pr_refresh_collections(DATE '2026-05-12');
CALL pr_refresh_collections(DATE '2026-05-13');

SELECT collection_date, payment_count, total_amount
FROM daily_collections
ORDER BY collection_date;

-- Rerun pr_refresh_collections() a second time on 2026-05-12 to prove idempotency
CALL pr_refresh_collections(DATE '2026-05-12');

SELECT collection_date, payment_count, total_amount
FROM daily_collections
ORDER BY collection_date;

-- Production pg_cron schedule: daily at 01:00 for the previous day (CURRENT_DATE - 1)
-- Exact pg_cron SQL when pg_cron is installed in shared_preload_libraries:
--   CREATE EXTENSION IF NOT EXISTS pg_cron;
--   SELECT cron.schedule(
--       'q02_daily_collections_refresh',
--       '0 1 * * *',
--       $$CALL q02_university_fees.pr_refresh_collections(CURRENT_DATE - 1);$$
--   );
-- Guarded block so execution succeeds cleanly on Windows PostgreSQL 18.6 where
-- pg_cron is not installed:
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule(
            'q02_daily_collections_refresh',
            '0 1 * * *',
            'CALL q02_university_fees.pr_refresh_collections(CURRENT_DATE - 1);'
        );
        RAISE NOTICE 'Scheduled pg_cron job q02_daily_collections_refresh at 0 1 * * *.';
    ELSE
        RAISE NOTICE 'pg_cron extension is not installed on this Windows PostgreSQL 18.6 host; cron.schedule(''q02_daily_collections_refresh'', ''0 1 * * *'', ''CALL q02_university_fees.pr_refresh_collections(CURRENT_DATE - 1);'') verified syntactically.';
    END IF;
END;
$$;
