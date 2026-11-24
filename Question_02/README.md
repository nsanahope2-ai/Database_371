# Question 2: University Fee Payments (50 Marks)

- **Course:** ICT371 Advanced Database
- **Student Name:** Hope Nsana
- **Student ID:** `202402859`
- **Database & Schema:** `ict371_final` / `q02_university_fees`
- **Verified Environment:** PostgreSQL 18.6 (`x86_64-windows`, `psql` 18.6)
- **Deliverables:** [`solution.sql`](./solution.sql) | [`output.txt`](./output.txt)

---

## Scenario Overview

A university requires accurate student fee balance calculations, strict prevention of credit balances (overpayments), automatic trigger-driven payment audit logging, a live view of students with outstanding balances (excluding settled students), indexed student-by-date-range payment queries, and an idempotent daily fee collection report scheduled at `01:00`.

### Schema Summary (`q02_university_fees`)

| Table | Primary Key | Foreign Keys | Key Constraints & Purpose |
| :--- | :--- | :--- | :--- |
| `students` | `student_id` (`SERIAL`) | — | `student_number UNIQUE NOT NULL`, `fee_due >= 0` |
| `payments` | `payment_id` (`SERIAL`) | `student_id -> students(student_id)` | `amount > 0`, `paid_on DATE NOT NULL` |
| `payment_audit` | `audit_id` (`SERIAL`) | `payment_id -> payments`, `student_id -> students` | `amount > 0`, `logged_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP` |
| `daily_collections` | `collection_date` (`DATE`) | — | `payment_count >= 0`, `total_amount >= 0`, upserted daily summary |

### Local PostgreSQL 18.6 Execution Note

- Executed against local PostgreSQL 18.6 (`psql -h localhost -U postgres -d ict371_final -v ON_ERROR_STOP=1 -e -f solution.sql`) with **exit code `0`**.
- Because `pg_cron` and `pgAgent` are not installed on local Windows PostgreSQL 18.6, Part **(g)** provides the exact `pg_cron` registration command (`cron.schedule(...)`) both explicitly and inside an extension-check `DO` block so `solution.sql` executes cleanly end-to-end with zero errors.

---

## Sub-Question Implementations & Live PostgreSQL 18.6 Results

### (a) Database and Seed Data [6 marks]

Four tables (`students`, `payments`, `payment_audit`, and `daily_collections`) are created in schema `q02_university_fees`. Three students are seeded with distinct `fee_due` obligations (`5000.00`, `4500.00`, and `6000.00`). Six valid payments are recorded via `pr_receive_payment` so that:
- **Student 1 (`STU-2024-001`, Mutale Banda):** `4` payments totaling `5000.00` against `5000.00` due -> **`0.00` balance (fully settled)**.
- **Student 2 (`STU-2024-002`, Thandiwe Phiri):** `2` payments totaling `2000.00` against `4500.00` due -> **`2500.00` balance (partially paid)**.
- **Student 3 (`STU-2024-003`, Kelvin Mwansa):** `0` payments against `6000.00` due -> **`6000.00` balance (no payments)**.

```sql
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
```

---

### (b) Function `fn_fee_balance` [6 marks]

`fn_fee_balance(p_student_id)` validates `p_student_id`, verifies the student exists in `students`, and returns `fee_due - COALESCE(SUM(amount), 0.00)`. When a student has no payments, `COALESCE(SUM(amount), 0.00)` evaluates to `0.00` and the full `fee_due` is returned.

```sql
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
```

**Verified Output (Initial Zero-Payment State & Invalid Student Rejections):**

```text
 student_id | student_number |   full_name    | fee_due | initial_balance 
------------+----------------+----------------+---------+-----------------
          1 | STU-2024-001   | Mutale Banda   | 5000.00 |         5000.00
          2 | STU-2024-002   | Thandiwe Phiri | 4500.00 |         4500.00
          3 | STU-2024-003   | Kelvin Mwansa  | 6000.00 |         6000.00
(3 rows)

NOTICE:  Expected rejection (unknown student): Unknown student_id (999). No matching student exists.
NOTICE:  Expected rejection (NULL student): Student ID cannot be NULL.
```

---

### (c) Procedure `pr_receive_payment` [8 marks]

`pr_receive_payment(p_student_id, p_amount, p_paid_on)` rejects `NULL`, zero, or negative amounts, `NULL` payment dates, unknown students, and any payment exceeding `fn_fee_balance(p_student_id)` (preventing credit balances). It locks the student row (`FOR UPDATE`) to serialize concurrent payments, inserts the valid row into `payments`, **leaves `students.fee_due` untouched**, and **does not insert into `payment_audit`** (delegating audit logging exclusively to the trigger).

```sql
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

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, ROUND(p_amount, 2), p_paid_on);
END;
$$;
```

**Verified Balances (`fee_due` Unchanged) & Rejection Tests:**

```text
 student_id | student_number |   full_name    | fee_due | current_balance 
------------+----------------+----------------+---------+-----------------
          1 | STU-2024-001   | Mutale Banda   | 5000.00 |            0.00
          2 | STU-2024-002   | Thandiwe Phiri | 4500.00 |         2500.00
          3 | STU-2024-003   | Kelvin Mwansa  | 6000.00 |         6000.00
(3 rows)

NOTICE:  Expected rejection (zero amount): Invalid payment amount (0.00). Amount must be strictly positive.
NOTICE:  Expected rejection (negative amount): Invalid payment amount (-250.00). Amount must be strictly positive.
NOTICE:  Expected rejection (NULL amount): Invalid payment amount (<NULL>). Amount must be strictly positive.
NOTICE:  Expected rejection (overpayment on partial balance): Overpayment rejected for student_id 2: outstanding balance = 2500.00, attempted payment = 3000.00. Credit balances are not allowed.
NOTICE:  Expected rejection (overpayment on settled student): Overpayment rejected for student_id 1: outstanding balance = 0.00, attempted payment = 1.00. Credit balances are not allowed.
NOTICE:  Expected rejection (unknown student): Unknown student_id (999). Cannot record payment.
NOTICE:  Payments count unchanged: before = 6, after = 6
NOTICE:  Audit count unchanged   : before = 6, after = 6
```

---

### (d) Payment Audit Trigger [8 marks]

`trg_payments_audit` is an `AFTER INSERT` row trigger on `payments` that automatically records `NEW.payment_id`, `NEW.student_id`, `NEW.amount`, and `CURRENT_TIMESTAMP` into `payment_audit`.

```sql
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
```

**Verified `payments` and Automatic `payment_audit` Rows:**

```text
 payment_id | student_id | amount  |  paid_on   
------------+------------+---------+------------
          1 |          1 | 1500.00 | 2026-05-10
          2 |          2 | 1250.00 | 2026-05-10
          3 |          1 | 1200.00 | 2026-05-11
          4 |          2 |  750.00 | 2026-05-11
          5 |          1 | 1300.00 | 2026-05-12
          6 |          1 | 1000.00 | 2026-05-12
(6 rows)

 audit_id | payment_id | student_id | amount  |           logged_at           
----------+------------+------------+---------+-------------------------------
        1 |          1 |          1 | 1500.00 | 2026-11-24 22:34:40.438374+02
        2 |          2 |          2 | 1250.00 | 2026-11-24 22:34:40.44184+02
        3 |          3 |          1 | 1200.00 | 2026-11-24 22:34:40.443019+02
        4 |          4 |          2 |  750.00 | 2026-11-24 22:34:40.444015+02
        5 |          5 |          1 | 1300.00 | 2026-11-24 22:34:40.446347+02
        6 |          6 |          1 | 1000.00 | 2026-11-24 22:34:40.4489+02
(6 rows)
```

---

### (e) Outstanding Balances View `v_fee_balances` [5 marks]

`v_fee_balances` joins `students` to `payments` with a `LEFT JOIN` (preserving students with zero payments such as Student 3) and filters via `HAVING (s.fee_due - COALESCE(SUM(p.amount), 0.00)) > 0` so fully settled students (Student 1, balance `0.00`) are excluded.

```sql
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
```

**Verified View Output (Student 1 Excluded; Students 2 & 3 Included):**

```text
 student_number |   full_name    | outstanding_balance 
----------------+----------------+---------------------
 STU-2024-002   | Thandiwe Phiri |             2500.00
 STU-2024-003   | Kelvin Mwansa  |             6000.00
(2 rows)
```

---

### (f) Composite Index & `EXPLAIN` Justification [5 marks]

```sql
CREATE INDEX idx_payments_student_paid_on
    ON payments (student_id, paid_on);

ANALYZE payments;
```

#### Design Justification (Equality First, Range Second)
1. **Leading Equality Column (`student_id`):** Filtering `WHERE student_id = 1` pins the B-tree lookup to the exact key prefix for Student 1.
2. **Trailing Range Column (`paid_on`):** Within Student 1's key prefix, index entries are sorted chronologically by `paid_on`, enabling PostgreSQL to satisfy `AND paid_on BETWEEN '2026-05-10' AND '2026-05-12'` in a single contiguous index scan (`Index Searches: 1`).
3. **Planner Behavior on Small vs. Large Tables:** With 6 seed rows fitting inside one 8 KB heap page (`Buffers: shared hit=1`), PostgreSQL's default cost model prefers a single-page `Seq Scan` (`cost=0.00..1.10`). Setting `SET LOCAL enable_seqscan = off` verifies that PostgreSQL uses `Index Scan using idx_payments_student_paid_on` with composite `Index Cond` pushdown, matching production behavior on multi-page payment tables.

**Live PostgreSQL 18.6 `EXPLAIN (ANALYZE, COSTS)` Output:**

```text
-- 1. Default planner setting on 6-row single-page table:
 Seq Scan on payments  (cost=0.00..1.10 rows=4 width=17) (actual time=0.046..0.050 rows=4.00 loops=1)
   Filter: ((paid_on >= '2026-05-10'::date) AND (paid_on <= '2026-05-12'::date) AND (student_id = 1))
   Rows Removed by Filter: 2
   Buffers: shared hit=1

-- 2. With SET LOCAL enable_seqscan = off (verifying Index Scan & composite Index Cond):
 Index Scan using idx_payments_student_paid_on on payments  (cost=0.13..12.22 rows=4 width=17) (actual time=0.109..0.111 rows=4.00 loops=1)
   Index Cond: ((student_id = 1) AND (paid_on >= '2026-05-10'::date) AND (paid_on <= '2026-05-12'::date))
   Index Searches: 1
   Buffers: shared hit=1 read=1
```

---

### (g) Scheduled Daily Collections Refresh (`pr_refresh_collections` & `pg_cron`) [6 marks]

`pr_refresh_collections(p_day)` computes `COUNT(payment_id)` and `COALESCE(SUM(amount), 0.00)` for `p_day` and upserts the summary row into `daily_collections` using `ON CONFLICT (collection_date) DO UPDATE`. Rerunning the procedure for `2026-05-12` replaces the summary cleanly without duplicating rows or inflating counts/amounts.

```sql
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

-- Daily schedule at 01:00 for the previous day (CURRENT_DATE - 1):
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q02_daily_collections_refresh',
    '0 1 * * *',
    $$CALL q02_university_fees.pr_refresh_collections(CURRENT_DATE - 1);$$
);
```

**Verified `daily_collections` Output (Before & After Rerun on `2026-05-12`):**

```text
 collection_date | payment_count | total_amount 
-----------------+---------------+--------------
 2026-05-10      |             2 |      2750.00
 2026-05-11      |             2 |      1950.00
 2026-05-12      |             2 |      2300.00
 2026-05-13      |             0 |         0.00
(4 rows)

-- After second CALL pr_refresh_collections(DATE '2026-05-12'):
 collection_date | payment_count | total_amount 
-----------------+---------------+--------------
 2026-05-10      |             2 |      2750.00
 2026-05-11      |             2 |      1950.00
 2026-05-12      |             2 |      2300.00
 2026-05-13      |             0 |         0.00
(4 rows)
```
