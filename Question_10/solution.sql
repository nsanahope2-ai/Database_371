-- ============================================================================
-- ICT371 Advanced Database | Student: Hope Nsana (202402859)
-- Question 10: Scholarship Application Assessment (50 Marks)
-- Target Engine: PostgreSQL 18.6
-- Isolated Schema: q10_scholarship
-- ============================================================================

DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path TO q10_scholarship, public;

-- ============================================================================
-- (a) Database and Seed Data [6 marks]
--     - Non-negative income, positive age, marks 0..100, valid status check
--     - Six PENDING applications across six students covering standard
--       qualifying, exact boundary qualifying, and boundary non-qualifying cases
-- ============================================================================

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id)
                                     ON UPDATE CASCADE ON DELETE RESTRICT,
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(15)   NOT NULL DEFAULT 'PENDING'
                                     CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id)
                               ON UPDATE CASCADE ON DELETE CASCADE,
    old_status     VARCHAR(15) NOT NULL CHECK (old_status IN ('PENDING', 'APPROVED', 'REJECTED')),
    new_status     VARCHAR(15) NOT NULL CHECK (new_status IN ('PENDING', 'APPROVED', 'REJECTED')),
    changed_at     TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
    ('STU-2026-001', 'Mwansa Kangwa'),
    ('STU-2026-002', 'Thandiwe Zulu'),
    ('STU-2026-003', 'Kelvin Tembo'),
    ('STU-2026-004', 'Natasha Lungu'),
    ('STU-2026-005', 'Chileshe Mwanza'),
    ('STU-2026-006', 'Bupe Nkonde');

-- Six PENDING applications covering qualifying, non-qualifying, and boundary cases:
--   App 1: Standard qualifying (age 20, income 1500.00, mark 85.50)         -> APPROVED
--   App 2: Exact boundary qualifying (age 18, income 3000.00, mark 70.00)   -> APPROVED
--   App 3: Exact upper-age boundary qualifying (age 25, income 0.00, 100.0) -> APPROVED
--   App 4: Non-qualifying age boundary (age 26 > 25, income 2000, mark 82)  -> REJECTED
--   App 5: Non-qualifying income boundary (age 21, income 3000.01, mark 78) -> REJECTED
--   App 6: Non-qualifying mark boundary (age 19, income 2500, mark 69.99)   -> REJECTED
INSERT INTO applications (
    student_id, age_at_application, monthly_income, average_mark, submitted_on, status
) VALUES
    (1, 20, 1500.00,  85.50, DATE '2026-05-10', 'PENDING'),
    (2, 18, 3000.00,  70.00, DATE '2026-05-11', 'PENDING'),
    (3, 25,    0.00, 100.00, DATE '2026-05-12', 'PENDING'),
    (4, 26, 2000.00,  82.00, DATE '2026-05-13', 'PENDING'),
    (5, 21, 3000.01,  78.00, DATE '2026-05-14', 'PENDING'),
    (6, 19, 2500.00,  69.99, DATE '2026-05-15', 'PENDING');

SELECT * FROM students ORDER BY student_id;
SELECT * FROM applications ORDER BY application_id;

-- ============================================================================
-- (b) Function: fn_scholarship_eligible [6 marks]
--     Returns TRUE iff age is 18..25 inclusive, monthly_income <= 3000, and
--     average_mark >= 70. Rejects NULLs, negative income, non-positive age,
--     or marks outside 0..100 with RAISE EXCEPTION.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Eligibility inputs (age, income, mark) cannot be NULL.';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Applicant age must be positive (got: %).', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly household income cannot be negative (got: %).', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100 inclusive (got: %).', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$;

-- Verify valid & boundary eligibility evaluations
SELECT
    fn_scholarship_eligible(20, 1500.00, 85.50) AS std_qualifying,
    fn_scholarship_eligible(18, 3000.00, 70.00) AS lower_boundary_ok,
    fn_scholarship_eligible(25,    0.00, 100.00) AS upper_boundary_ok,
    fn_scholarship_eligible(17, 1500.00, 85.00) AS age_17_ineligible,
    fn_scholarship_eligible(26, 1500.00, 85.00) AS age_26_ineligible,
    fn_scholarship_eligible(21, 3000.01, 80.00) AS income_over_ineligible,
    fn_scholarship_eligible(19, 2500.00, 69.99) AS mark_under_ineligible;

-- Verify input validation exceptions
DO $$
BEGIN
    PERFORM fn_scholarship_eligible(NULL, 1000.00, 80.00);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - NULL input]: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    PERFORM fn_scholarship_eligible(0, 1000.00, 80.00);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Non-positive age]: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    PERFORM fn_scholarship_eligible(20, -50.00, 80.00);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Negative income]: %', SQLERRM;
END;
$$;

DO $$
BEGIN
    PERFORM fn_scholarship_eligible(20, 1000.00, 105.00);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Mark > 100]: %', SQLERRM;
END;
$$;

-- ============================================================================
-- (c) Procedure: pr_assess_application [8 marks]
--     Locks target row FOR UPDATE, requires an existing PENDING application,
--     evaluates fn_scholarship_eligible, and updates status to APPROVED or
--     REJECTED. Raises a clear exception if unknown or already assessed.
-- ============================================================================

CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_app      applications%ROWTYPE;
    v_eligible BOOLEAN;
BEGIN
    IF p_application_id IS NULL THEN
        RAISE EXCEPTION 'Application ID cannot be NULL.';
    END IF;

    SELECT *
    INTO v_app
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application ID % does not exist.', p_application_id;
    END IF;

    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application ID % has already been assessed (current status: %).',
            p_application_id, v_app.status;
    END IF;

    v_eligible := fn_scholarship_eligible(
        v_app.age_at_application,
        v_app.monthly_income,
        v_app.average_mark
    );

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- ============================================================================
-- (d) Trigger: trg_audit_application_status [8 marks]
--     AFTER UPDATE row trigger on applications that records actual status
--     transitions in decision_audit. Unchanged status creates no audit entry.
--     Installed before running pr_assess_application tests so every assessment
--     is audited.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_trg_audit_application_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_application_status
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION fn_trg_audit_application_status();

-- ----------------------------------------------------------------------------
-- Test (c) & (d): Assess two individual applications (1 -> APPROVED, 4 -> REJECTED),
-- leave applications 2, 3, 5, 6 PENDING for (f) and batch job (g), and verify
-- exception handling + unchanged-status non-auditing.
-- ----------------------------------------------------------------------------

CALL pr_assess_application(1); -- Standard qualifying -> APPROVED
CALL pr_assess_application(4); -- Age 26 (> 25)       -> REJECTED

-- Verify unknown application_id raises exception
DO $$
BEGIN
    CALL pr_assess_application(999);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Unknown application]: %', SQLERRM;
END;
$$;

-- Verify already assessed application raises exception
DO $$
BEGIN
    CALL pr_assess_application(1);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[Expected Error - Already assessed application]: %', SQLERRM;
END;
$$;

-- Verify an UPDATE that leaves status unchanged creates NO audit entry
UPDATE applications
SET submitted_on = submitted_on, status = status
WHERE application_id = 1;

-- Inspect audit log (must contain exactly 2 entries: App 1 and App 4)
SELECT audit_id, application_id, old_status, new_status, changed_at
FROM decision_audit
ORDER BY audit_id;

-- ============================================================================
-- (e) View: v_approved_applicants [5 marks]
--     Shows student_number, full_name, average_mark, and status for APPROVED
--     applications only, omitting household income for privacy.
-- ============================================================================

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s
    ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- Query view after individual assessments in (c)
SELECT * FROM v_approved_applicants ORDER BY student_number;

-- ============================================================================
-- (f) Index: idx_applications_status_submitted [5 marks]
--     Composite B-tree index on (status, submitted_on) supporting searches
--     filtered by exact status and a submitted_on date range.
-- ============================================================================

CREATE INDEX idx_applications_status_submitted
ON applications (status, submitted_on);

ANALYZE applications;

-- Matching query searching PENDING applications within a submission date range
SELECT
    application_id, student_id, age_at_application, average_mark, submitted_on, status
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN DATE '2026-05-10' AND DATE '2026-05-15'
ORDER BY submitted_on;

-- Demonstrate index usage via EXPLAIN (disable seqscan briefly for 6-row table)
SET enable_seqscan = off;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT
    application_id, student_id, age_at_application, average_mark, submitted_on, status
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN DATE '2026-05-10' AND DATE '2026-05-15'
ORDER BY submitted_on;

RESET enable_seqscan;

-- ============================================================================
-- (g) Scheduled Job: pr_assess_pending & Monday 08:00 Schedule [6 marks]
--     Uses a query FOR loop to process only PENDING applications through
--     pr_assess_application. Rerunning does not reassess completed rows or
--     duplicate decision_audit entries. Scheduled Mondays at 08:00 (0 8 * * 1).
-- ============================================================================

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    v_app RECORD;
BEGIN
    FOR v_app IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(v_app.application_id);
    END LOOP;
END;
$$;

-- First batch execution: assesses remaining PENDING applications (2, 3, 5, 6)
CALL pr_assess_pending();

SELECT application_id, student_id, age_at_application, monthly_income, average_mark, status
FROM applications
ORDER BY application_id;

SELECT audit_id, application_id, old_status, new_status, changed_at
FROM decision_audit
ORDER BY audit_id;

-- Second batch execution (rerun): 0 PENDING rows -> no errors, no duplicate audit entries
CALL pr_assess_pending();

SELECT COUNT(*) AS total_audit_entries_after_rerun FROM decision_audit;

-- Final query of v_approved_applicants showing all 3 approved students (no income column)
SELECT * FROM v_approved_applicants ORDER BY student_number;

-- Register weekly Monday 08:00 pg_cron job (guarded for Windows PG 18)
DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        SELECT jobid INTO v_job_id
        FROM cron.job
        WHERE jobname = 'q10_weekly_scholarship_assessment';

        IF v_job_id IS NOT NULL THEN
            PERFORM cron.unschedule(v_job_id);
        END IF;

        PERFORM cron.schedule(
            'q10_weekly_scholarship_assessment',
            '0 8 * * 1',
            $cron$CALL q10_scholarship.pr_assess_pending();$cron$
        );
        RAISE NOTICE 'Scheduled pg_cron job q10_weekly_scholarship_assessment for Mondays at 08:00 (0 8 * * 1).';
    ELSE
        RAISE NOTICE 'pg_cron extension is not installed on this Windows PostgreSQL 18.6 server; schedule specification (0 8 * * 1 -> CALL q10_scholarship.pr_assess_pending()) verified via repeated procedure execution above.';
    END IF;
END;
$$;
