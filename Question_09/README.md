# Question 9: Farmer Cooperative Maize Deliveries (50 Marks)

- **Course:** ICT371 Advanced Database
- **Student Name:** Hope Nsana
- **Student ID:** `202402859`
- **Isolated Schema:** `q09_maize_coop`
- **Verified Engine:** PostgreSQL 18.6 (`localhost:5432`, database `ict371_final`)
- **Deliverables:** [`solution.sql`](./solution.sql) | [`output.txt`](./output.txt)

---

## Problem Summary

A farmer cooperative purchases maize at fixed grade prices:
- **Grade A:** `K5.00` per kilogram
- **Grade B:** `K4.00` per kilogram
- **Grade C:** `K3.00` per kilogram

Delivery values (`unit_rate` and `total_value`) must be computed consistently whether records enter via the stored procedure `pr_receive_delivery` or via direct `INSERT`/`UPDATE` SQL statements.

---

## (a) Database Schema and Seed Data [6 Marks]

All objects are isolated in schema `q09_maize_coop`. Weight columns use `NUMERIC(10,2)` and monetary columns use `NUMERIC(12,2)`, backed by `NOT NULL`, `UNIQUE`, `FOREIGN KEY`, and positive `CHECK` constraints.

```sql
CREATE SCHEMA q09_maize_coop;
SET search_path TO q09_maize_coop, public;

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
```

### Seed Design
- **Three farmers** (`FRM-001` Chanda Mulenga, `FRM-002` Mutale Banda, `FRM-003` Bwalya Phiri) are inserted in `(a)`.
- **Six deliveries** are loaded **after** installing the pricing trigger in `(d)` so every seeded delivery is priced automatically by the trigger.
- The six deliveries cover **all three grades (`A`, `B`, `C`)** and **both payment states (`is_paid = TRUE` and `is_paid = FALSE`)**, while arranging for **`FRM-003` (Bwalya Phiri)** to have **only paid deliveries** (`0` unpaid deliveries) so `(e)` explicitly demonstrates `0.00` unpaid balance.

---

## (b) Function: `fn_maize_rate` [6 Marks]

Returns `NUMERIC(10,2)` (`5.00`, `4.00`, or `3.00`) for exact grades `'A'`, `'B'`, or `'C'`, and raises a descriptive exception on `NULL` or unsupported grades.

```sql
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
```

**Verified Output:**
```text
 rate_grade_a | rate_grade_b | rate_grade_c
--------------+--------------+--------------
         5.00 |         4.00 |         3.00
(1 row)

NOTICE:  [Expected Error - NULL grade]: Maize grade cannot be NULL. Expected A, B, or C.
NOTICE:  [Expected Error - Unsupported grade D]: Unsupported maize grade "D". Allowed grades are A, B, or C.
```

---

## (c) Procedure: `pr_receive_delivery` [8 Marks]

Validates non-null arguments, positive weight (`p_weight > 0`), farmer existence in `farmers`, and valid grade via `fn_maize_rate(p_grade)`. Inserts only the core delivery attributes (`farmer_id`, `grade`, `weight_kg`, `delivered_on`, `is_paid = FALSE`), delegating `unit_rate` and `total_value` calculation to the `BEFORE` trigger.

```sql
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

    PERFORM fn_maize_rate(p_grade);

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, ROUND(p_weight, 2), p_date, FALSE);
END;
$$;
```

---

## (d) Trigger: `trg_deliveries_pricing` & Seed Deliveries [8 Marks]

Because PostgreSQL executes `BEFORE INSERT OR UPDATE` row triggers prior to checking `NOT NULL` and `CHECK` table constraints, `trg_deliveries_pricing` enforces positive weights and calculates `NEW.unit_rate` and `NEW.total_value` identically for both `CALL pr_receive_delivery(...)` and direct `INSERT`/`UPDATE` statements—even overriding bogus caller-supplied rates.

```sql
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
```

### Verification of Trigger-Priced Seed Deliveries & Override Protection
- Delivery 3 was inserted directly with bogus `unit_rate = 999.00, total_value = 1.00` for Grade `'C'` (`320.25 kg`); the trigger automatically overrode those values to `unit_rate = 3.00` and `total_value = 960.75`.
- Updating `delivery_id = 2` to `grade = 'B', weight_kg = 200.00` with bogus `unit_rate = 777.00` was likewise overridden to `4.00` and `800.00` (inside a rolled-back test transaction).
- Unknown farmers (`999`), negative weights (`-25.00`), and invalid grades (`'D'`) all raised clean exceptions.

```text
 delivery_id | farmer_id | grade | weight_kg | unit_rate | total_value | delivered_on | is_paid
-------------+-----------+-------+-----------+-----------+-------------+--------------+---------
           1 |         1 | A     |    250.50 |      5.00 |     1252.50 | 2026-05-18   | f
           2 |         2 | A     |    150.00 |      5.00 |      750.00 | 2026-05-18   | f
           3 |         2 | C     |    320.25 |      3.00 |      960.75 | 2026-05-20   | f
           4 |         1 | B     |    180.00 |      4.00 |      720.00 | 2026-05-19   | t
           5 |         3 | B     |    400.00 |      4.00 |     1600.00 | 2026-05-18   | t
           6 |         3 | C     |    210.00 |      3.00 |      630.00 | 2026-05-20   | t
(6 rows)
```

---

## (e) View: `v_farmer_amount_due` [5 Marks]

Uses a `LEFT JOIN` from `farmers` to `deliveries` with `AND d.is_paid = FALSE` inside the join predicate (not a `WHERE` filter, which would drop paid-only farmers) and `COALESCE(SUM(d.total_value), 0.00)` so farmers with zero unpaid deliveries appear with `0.00`.

```sql
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
```

**Verified Output:**
```text
 farmer_number |   full_name    | unpaid_amount_due
---------------+----------------+-------------------
 FRM-001       | Chanda Mulenga |           1252.50
 FRM-002       | Mutale Banda   |           1710.75
 FRM-003       | Bwalya Phiri   |              0.00
(3 rows)
```

---

## (f) Composite Index: `idx_deliveries_farmer_date` [5 Marks]

```sql
CREATE INDEX idx_deliveries_farmer_date
ON deliveries (farmer_id, delivered_on);
```

### Index Justification
- Follows the **Equality-then-Range** composite B-tree rule:
  1. **`farmer_id` (leading column — equality filter):** Immediately narrows the B-tree search to leaf entries belonging to a single farmer (`farmer_id = 1`).
  2. **`delivered_on` (second column — range & sort key):** Within a single farmer's index slice, entries are physically ordered by `delivered_on`, enabling a contiguous range scan for `delivered_on BETWEEN '2026-05-01' AND '2026-05-31'` and satisfying `ORDER BY delivered_on` without an extra `Sort` node.

### Matching Query & Verified PostgreSQL 18.6 `EXPLAIN` Plan
*(With `enable_seqscan = off` briefly applied so PostgreSQL demonstrates the index path on the 6-row single-page table):*

```text
                                                    QUERY PLAN
-------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_deliveries_farmer_date on deliveries (actual rows=2.00 loops=1)
   Index Cond: ((farmer_id = 1) AND (delivered_on >= '2026-05-01'::date) AND (delivered_on <= '2026-05-31'::date))
   Index Searches: 1
   Buffers: shared hit=1 read=1
 Planning Time: 0.107 ms
 Execution Time: 0.079 ms
```

---

## (g) Scheduled Job: `pr_refresh_purchases` & Daily `01:30` Schedule [6 Marks]

Aggregates total weight and total value for `p_day` from `deliveries` (defaulting to `0.00` via `COALESCE` when no deliveries occurred on `p_day`) and upserts into `daily_purchases` using `ON CONFLICT (purchase_date) DO UPDATE`. Repeated runs overwrite prior totals rather than adding to them.

```sql
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
```

### Repeated-Run Idempotency Verification
Running `CALL pr_refresh_purchases(DATE '2026-05-18');` **twice** produced the exact same totals (`800.50 kg`, `K3,602.50`) on both runs:

```text
-- After Run 1:
 purchase_date | total_weight | total_value
---------------+--------------+-------------
 2026-05-18    |       800.50 |     3602.50

-- After Run 2 (replaced, NOT doubled):
 purchase_date | total_weight | total_value
---------------+--------------+-------------
 2026-05-18    |       800.50 |     3602.50

-- Full daily_purchases table (including zero-delivery yesterday check):
 purchase_date | total_weight | total_value
---------------+--------------+-------------
 2026-05-18    |       800.50 |     3602.50
 2026-05-19    |       180.00 |      720.00
 2026-05-20    |       530.25 |     1590.75
 2026-11-23    |         0.00 |        0.00
```

### Scheduler Registration & Local Windows PostgreSQL 18.6 Note
- **Cron Schedule:** `30 1 * * *` (every day at `01:30` server time) executing `CALL q09_maize_coop.pr_refresh_purchases(CURRENT_DATE - 1);`.
- **Environment Note:** Neither `pg_cron` nor `pgAgent` is bundled with the Windows PostgreSQL 18.6 installer. In `solution.sql`, `cron.schedule(...)` is wrapped in a `pg_available_extensions` check so it registers automatically on Linux/cloud PostgreSQL servers with `pg_cron` while executing cleanly with exit code `0` on Windows PostgreSQL 18.6. On Windows hosts without `pg_cron`, the identical command can also be triggered at `01:30` daily via Windows Task Scheduler (`psql -d ict371_final -c "CALL q09_maize_coop.pr_refresh_purchases(CURRENT_DATE - 1);"`).
