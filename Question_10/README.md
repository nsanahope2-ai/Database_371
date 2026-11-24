# Question 10: Scholarship Application Assessment (50 Marks)

- **Course:** ICT371 Advanced Database
- **Student Name:** Hope Nsana
- **Student ID:** `202402859`
- **Isolated Schema:** `q10_scholarship`
- **Verified Engine:** PostgreSQL 18.6 (`localhost:5432`, database `ict371_final`)
- **Deliverables:** [`solution.sql`](./solution.sql) | [`output.txt`](./output.txt)

---

## Problem Summary

Applicants qualify for a scholarship only when **all three** criteria hold simultaneously:
1. **Age at application:** `18` to `25` inclusive (`18 <= age_at_application <= 25`)
2. **Monthly household income:** at most `K3,000.00` (`monthly_income <= 3000.00`)
3. **Average academic mark:** at least `70.00` (`average_mark >= 70.00`)

Application statuses are `PENDING`, `APPROVED`, and `REJECTED`, and every genuine status transition must be recorded in `decision_audit`.

---

## (a) Database Schema and Seed Data [6 Marks]

All tables are created in schema `q10_scholarship` with domain integrity constraints (`age_at_application > 0`, `monthly_income >= 0`, `average_mark BETWEEN 0 AND 100`, and `status IN ('PENDING', 'APPROVED', 'REJECTED')`).

```sql
CREATE SCHEMA q10_scholarship;
SET search_path TO q10_scholarship, public;

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
```

### Seeded `PENDING` Applications (Qualifying, Non-Qualifying & Boundary Cases)

| App ID | Student | Age | Monthly Income | Average Mark | Case Tested | Expected Outcome |
| :---: | :--- | :---: | :---: | :---: | :--- | :---: |
| `1` | `STU-2026-001` Mwansa Kangwa | `20` | `1500.00` | `85.50` | Standard qualifying | `APPROVED` |
| `2` | `STU-2026-002` Thandiwe Zulu | `18` | `3000.00` | `70.00` | Exact min-age (`18`), max-income (`3000`), min-mark (`70`) boundaries | `APPROVED` |
| `3` | `STU-2026-003` Kelvin Tembo | `25` | `0.00` | `100.00` | Exact max-age (`25`), zero-income (`0`), max-mark (`100`) boundaries | `APPROVED` |
| `4` | `STU-2026-004` Natasha Lungu | `26` | `2000.00` | `82.00` | Non-qualifying upper age boundary (`26 > 25`) | `REJECTED` |
| `5` | `STU-2026-005` Chileshe Mwanza | `21` | `3000.01` | `78.00` | Non-qualifying income boundary (`3000.01 > 3000`) | `REJECTED` |
| `6` | `STU-2026-006` Bupe Nkonde | `19` | `2500.00` | `69.99` | Non-qualifying mark boundary (`69.99 < 70`) | `REJECTED` |

---

## (b) Function: `fn_scholarship_eligible` [6 Marks]

Validates that no input is `NULL`, `p_age > 0`, `p_income >= 0`, and `p_mark BETWEEN 0 AND 100`, raising descriptive exceptions otherwise, then returns a `BOOLEAN` covering all three eligibility thresholds.

```sql
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
```

**Verified Output:**
```text
 std_qualifying | lower_boundary_ok | upper_boundary_ok | age_17_ineligible | age_26_ineligible | income_over_ineligible | mark_under_ineligible
----------------+-------------------+-------------------+-------------------+-------------------+------------------------+-----------------------
 t              | t                 | t                 | f                 | f                 | f                      | f
(1 row)

NOTICE:  [Expected Error - NULL input]: Eligibility inputs (age, income, mark) cannot be NULL.
NOTICE:  [Expected Error - Non-positive age]: Applicant age must be positive (got: 0).
NOTICE:  [Expected Error - Negative income]: Monthly household income cannot be negative (got: -50.00).
NOTICE:  [Expected Error - Mark > 100]: Average mark must be between 0 and 100 inclusive (got: 105.00).
```

---

## (c) Procedure: `pr_assess_application` [8 Marks]

Acquires a row-level exclusive lock (`SELECT ... FOR UPDATE`) to prevent concurrent double-assessment, verifies the application exists and is currently `'PENDING'`, evaluates `fn_scholarship_eligible(...)`, and updates `status` to `'APPROVED'` or `'REJECTED'`.

```sql
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
```

---

## (d) Trigger: `trg_audit_application_status` [8 Marks]

Uses both a trigger-level `WHEN (OLD.status IS DISTINCT FROM NEW.status)` clause and an internal guard so `decision_audit` logs **only** genuine status transitions and ignores updates that leave `status` unchanged.

```sql
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
```

### Verification of `(c)` and `(d)`
- Assessed Application `1` (`APPROVED`) and Application `4` (`REJECTED`).
- Calling `pr_assess_application(999)` and `pr_assess_application(1)` raised the expected exceptions (`Application ID 999 does not exist` and `Application ID 1 has already been assessed (current status: APPROVED)`).
- Running `UPDATE applications SET submitted_on = submitted_on, status = status WHERE application_id = 1;` updated `1` row without changing `status` and added **zero** rows to `decision_audit`:

```text
 audit_id | application_id | old_status | new_status |         changed_at
----------+----------------+------------+------------+----------------------------
        1 |              1 | PENDING    | APPROVED   | 2026-11-24 22:35:29.351000
        2 |              4 | PENDING    | REJECTED   | 2026-11-24 22:35:29.354000
(2 rows)
```

---

## (e) View: `v_approved_applicants` [5 Marks]

Exposes `student_number`, `full_name`, `average_mark`, and `status` strictly for `'APPROVED'` applications while omitting `monthly_income` to protect household financial privacy.

```sql
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
```

**Verified Output (After Full Assessment in `(g)`):**
```text
 student_number |   full_name   | average_mark |  status
----------------+---------------+--------------+----------
 STU-2026-001   | Mwansa Kangwa |        85.50 | APPROVED
 STU-2026-002   | Thandiwe Zulu |        70.00 | APPROVED
 STU-2026-003   | Kelvin Tembo  |       100.00 | APPROVED
(3 rows)
```

---

## (f) Composite Index: `idx_applications_status_submitted` [5 Marks]

```sql
CREATE INDEX idx_applications_status_submitted
ON applications (status, submitted_on);
```

### Index Justification
- Places the **equality column (`status`) first** and the **range/ordering column (`submitted_on`) second**:
  1. Seeking `status = 'PENDING'` jumps directly to the `'PENDING'` partition of the B-tree.
  2. Within `'PENDING'`, entries are sorted chronologically by `submitted_on`, allowing `submitted_on BETWEEN '2026-05-10' AND '2026-05-15'` and `ORDER BY submitted_on` to be satisfied in a single contiguous index scan with zero sort overhead.

### Matching Query & Verified PostgreSQL 18.6 `EXPLAIN` Plan
*(With `enable_seqscan = off` briefly applied to demonstrate index selection on the 6-row seed table):*

```text
                                                              QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_applications_status_submitted on applications (actual rows=4.00 loops=1)
   Index Cond: (((status)::text = 'PENDING'::text) AND (submitted_on >= '2026-05-10'::date) AND (submitted_on <= '2026-05-15'::date))
   Index Searches: 1
   Buffers: shared hit=1 read=1
 Planning Time: 0.154 ms
 Execution Time: 0.107 ms
```

---

## (g) Scheduled Job: `pr_assess_pending` & Monday `08:00` Schedule [6 Marks]

Iterates over only `PENDING` applications using a PL/pgSQL query `FOR` loop and delegates each row to `pr_assess_application`.

```sql
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
```

### Batch Execution & Rerun Verification
1. **First `CALL pr_assess_pending();`:** Assessed the remaining four `PENDING` applications (`2` -> `APPROVED`, `3` -> `APPROVED`, `5` -> `REJECTED`, `6` -> `REJECTED`), bringing `decision_audit` to `6` total rows (one per application).
2. **Second `CALL pr_assess_pending();` (Rerun):** Selected `0` `PENDING` rows, completed without error, did not reassess completed applications, and left `decision_audit` unchanged at `6` rows (`total_audit_entries_after_rerun = 6`).

```text
 application_id | student_id | age_at_application | monthly_income | average_mark |  status
----------------+------------+--------------------+----------------+--------------+----------
              1 |          1 |                 20 |        1500.00 |        85.50 | APPROVED
              2 |          2 |                 18 |        3000.00 |        70.00 | APPROVED
              3 |          3 |                 25 |           0.00 |       100.00 | APPROVED
              4 |          4 |                 26 |        2000.00 |        82.00 | REJECTED
              5 |          5 |                 21 |        3000.01 |        78.00 | REJECTED
              6 |          6 |                 19 |        2500.00 |        69.99 | REJECTED
(6 rows)
```

### Scheduler Registration & Local Windows PostgreSQL 18.6 Note
- **Cron Schedule:** `0 8 * * 1` (every Monday at `08:00` server time) executing `CALL q10_scholarship.pr_assess_pending();`.
- **Environment Note:** Neither `pg_cron` nor `pgAgent` is installed on this Windows PostgreSQL 18.6 server. `solution.sql` wraps `cron.schedule(...)` inside an extension-availability guard (`pg_available_extensions`) so it registers automatically when `pg_cron` is available and exits cleanly (`0`) on Windows PostgreSQL 18.6. On Windows servers without `pg_cron`, Windows Task Scheduler can invoke `psql -d ict371_final -c "CALL q10_scholarship.pr_assess_pending();"` every Monday at `08:00`.
