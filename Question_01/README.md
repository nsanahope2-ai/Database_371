# Question 1: Pharmacy Stock and Daily Sales (50 Marks)

- **Course:** ICT371 Advanced Database
- **Student Name:** Hope Nsana
- **Student ID:** `202402859`
- **Database & Schema:** `ict371_final` / `q01_pharmacy`
- **Verified Environment:** PostgreSQL 18.6 (`x86_64-windows`, `psql` 18.6)
- **Deliverables:** [`solution.sql`](./solution.sql) | [`output.txt`](./output.txt)

---

## Scenario Overview

A pharmacy needs to record medicine sales accurately, prevent overselling under concurrent access, retain a complete stock-change audit trail, monitor low-stock items, optimize medicine-by-date-range sales lookups, and maintain idempotent daily sales revenue summaries.

### Schema Summary (`q01_pharmacy`)

| Table | Primary Key | Foreign Keys | Key Constraints & Purpose |
| :--- | :--- | :--- | :--- |
| `medicines` | `medicine_id` (`SERIAL`) | — | `medicine_name UNIQUE NOT NULL`, `unit_price > 0`, `stock_qty >= 0` |
| `sales` | `sale_id` (`SERIAL`) | `medicine_id -> medicines(medicine_id)` | `quantity > 0`, `unit_price > 0`, snapshots selling price at time of sale |
| `stock_audit` | `audit_id` (`SERIAL`) | `medicine_id -> medicines(medicine_id)` | `old_qty >= 0`, `new_qty >= 0`, `changed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP` |
| `daily_sales` | `sales_date` (`DATE`) | — | `total_qty >= 0`, `total_amount >= 0`, upserted daily summary |

### Local PostgreSQL 18.6 Execution Note

- Executed against local PostgreSQL 18.6 (`psql -h localhost -U postgres -d ict371_final -v ON_ERROR_STOP=1 -e -f solution.sql`) with **exit code `0`**.
- Neither `pg_cron` (a Unix/Linux background-worker extension not shipped with Windows PostgreSQL 18 installers) nor `pgAgent` is installed on this Windows host. Part **(g)** provides the exact `pg_cron` registration SQL (`cron.schedule(...)`) both verbatim and wrapped inside a `pg_available_extensions` guard so `solution.sql` executes cleanly from top to bottom without error.

---

## Sub-Question Implementations & Live PostgreSQL 18.6 Results

### (a) Database and Seed Data [6 marks]

Four relational tables (`medicines`, `sales`, `stock_audit`, and `daily_sales`) are created in schema `q01_pharmacy` with strict `CHECK`, `NOT NULL`, `UNIQUE`, `PRIMARY KEY`, and `FOREIGN KEY` constraints. Four medicines are seeded initially, and valid seed sales (`7` initial sales + `1` additional sale in Part (e) = `8` valid sales total) are loaded strictly through the completed `pr_record_sale` procedure so stock deductions and `stock_audit` rows are generated organically.

```sql
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
```

**Initial `medicines` seed state:**

```text
 medicine_id |       medicine_name        | unit_price | stock_qty 
-------------+----------------------------+------------+-----------
           1 | Amoxicillin 500mg Capsules |      12.50 |        25
           2 | Paracetamol 500mg Tablets  |       5.00 |        40
           3 | Ibuprofen 400mg Tablets    |       8.75 |        15
           4 | Cetirizine 10mg Tablets    |       6.20 |        12
(4 rows)
```

---

### (b) Function `fn_sale_value` [6 marks]

`fn_sale_value(p_medicine_id, p_quantity)` validates that `p_medicine_id` is non-null and exists in `medicines`, validates that `p_quantity` is strictly positive (`> 0`), and returns `ROUND(unit_price * p_quantity, 2)`.

```sql
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
```

**Verified Output (Valid Calls & Exception Rejections):**

```text
 amoxicillin_4_units | paracetamol_7_units | ibuprofen_3_units 
---------------------+---------------------+-------------------
               50.00 |               35.00 |             26.25
(1 row)

NOTICE:  Expected rejection (unknown medicine): Unknown medicine_id (999). No matching medicine exists.
NOTICE:  Expected rejection (zero quantity): Invalid quantity (0). Quantity must be a positive integer.
NOTICE:  Expected rejection (negative quantity): Invalid quantity (-5). Quantity must be a positive integer.
NOTICE:  Expected rejection (NULL quantity): Invalid quantity (<NULL>). Quantity must be a positive integer.
```

---

### (c) Procedure `pr_record_sale` [8 marks]

`pr_record_sale(p_medicine_id, p_quantity, p_sold_on)` validates inputs via `fn_sale_value`, acquires a row-level lock (`SELECT ... FOR UPDATE`) on `medicines` to prevent concurrent overselling, checks `v_stock_qty >= p_quantity`, snapshots the current `unit_price` into `sales`, and deducts `stock_qty` exactly once. Because PL/pgSQL procedures execute each statement atomically within the surrounding transaction/subtransaction block, any exception rolls back partial effects and leaves both `medicines` and `sales` unchanged.

```sql
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

    v_sale_value := fn_sale_value(p_medicine_id, p_quantity);

    SELECT m.unit_price, m.stock_qty
      INTO v_unit_price, v_stock_qty
      FROM medicines m
     WHERE m.medicine_id = p_medicine_id
       FOR UPDATE;

    IF v_stock_qty < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id %: available = %, requested = %.',
            p_medicine_id, v_stock_qty, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_unit_price, p_sold_on);

    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;
```

**Seed Sales Recorded via `pr_record_sale` & Invalid Sale Verification:**

```text
 sale_id | medicine_id | quantity | unit_price |  sold_on   
---------+-------------+----------+------------+------------
       1 |           1 |        6 |      12.50 | 2026-05-10
       2 |           2 |       10 |       5.00 | 2026-05-10
       3 |           1 |        5 |      12.50 | 2026-05-11
       4 |           3 |        9 |       8.75 | 2026-05-11
       5 |           2 |        8 |       5.00 | 2026-05-11
       6 |           1 |        7 |      12.50 | 2026-05-12
       7 |           4 |        2 |       6.20 | 2026-05-12
(7 rows)

NOTICE:  Expected rejection (oversell): Insufficient stock for medicine_id 3: available = 6, requested = 50.
NOTICE:  Expected rejection (unknown medicine): Unknown medicine_id (999). No matching medicine exists.
NOTICE:  Expected rejection (negative quantity): Invalid quantity (-2). Quantity must be a positive integer.
NOTICE:  Sales count unchanged: before = 7, after = 7
NOTICE:  Medicine 3 stock_qty unchanged: before = 6, after = 6
```

---

### (d) Stock Audit Trigger [8 marks]

`trg_medicines_stock_audit` is an `AFTER UPDATE` row-level trigger on `medicines` with `WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)` (also verified inside `fn_trg_medicines_stock_audit()`). Non-stock updates (such as changing `unit_price` from `12.50` to `13.00`) do **not** fire or insert spurious audit rows.

```sql
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
```

**Verified Audit Log & Non-Stock Update Test:**

```text
 audit_id | medicine_id | old_qty | new_qty |          changed_at           
----------+-------------+---------+---------+-------------------------------
        1 |           1 |      25 |      19 | 2026-11-24 22:34:40.022309+02
        2 |           2 |      40 |      30 | 2026-11-24 22:34:40.02742+02
        3 |           1 |      19 |      14 | 2026-11-24 22:34:40.029831+02
        4 |           3 |      15 |       6 | 2026-11-24 22:34:40.031647+02
        5 |           2 |      30 |      22 | 2026-11-24 22:34:40.032782+02
        6 |           1 |      14 |       7 | 2026-11-24 22:34:40.034141+02
        7 |           4 |      12 |      10 | 2026-11-24 22:34:40.035533+02
(7 rows)

-- Price-only update (UPDATE medicines SET unit_price = 13.00 WHERE medicine_id = 1):
 audit_rows_before_price_update | 7
 audit_rows_after_price_update  | 7
```

---

### (e) Low-Stock View `v_low_stock` [5 marks]

`v_low_stock` returns all medicines with `stock_qty < 10`, exposing `medicine_id`, `medicine_name`, `unit_price`, and `stock_qty`. Recording a sale of `3` units of Cetirizine (`CALL pr_record_sale(4, 3, DATE '2026-05-12')`) lowers its stock from `10` to `7`, causing it to appear immediately in `v_low_stock` alongside Ibuprofen (`6`) and Amoxicillin (`7`), while Paracetamol (`22`) remains excluded.

```sql
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty
FROM medicines
WHERE stock_qty < 10
ORDER BY stock_qty ASC, medicine_id ASC;
```

**Verified Query Result After Sale:**

```text
 medicine_id |       medicine_name        | unit_price | stock_qty 
-------------+----------------------------+------------+-----------
           3 | Ibuprofen 400mg Tablets    |       8.75 |         6
           1 | Amoxicillin 500mg Capsules |      13.00 |         7
           4 | Cetirizine 10mg Tablets    |       6.20 |         7
(3 rows)
```

---

### (f) Composite Index & `EXPLAIN` Justification [5 marks]

```sql
CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);

ANALYZE sales;
```

#### Design Justification (Equality First, Range Second)
1. **Leading Equality Column (`medicine_id`):** Queries for a single medicine filter with an equality predicate (`WHERE medicine_id = 1`). Placing `medicine_id` first narrows the B-tree traversal immediately to the contiguous leaf slice belonging to that single medicine.
2. **Trailing Range Column (`sold_on`):** Within a fixed `medicine_id`, leaf entries are physically ordered by `sold_on`. PostgreSQL satisfies `AND sold_on BETWEEN '2026-05-10' AND '2026-05-12'` in a single bounded range scan (`Index Searches: 1`) without sorting or scanning unrelated medicines. Reversing the column order (`(sold_on, medicine_id)`) would force PostgreSQL to scan across every medicine sold in that date window.
3. **Planner Behavior on Small vs. Large Tables:** Because the 8 seed rows occupy a single 8 KB heap page (`Buffers: shared hit=1`), PostgreSQL's cost optimizer chooses a single-page `Seq Scan` (`cost=0.00..1.14`) under default settings rather than reading both an index page and a heap page. Disabling the single-page sequential shortcut (`SET LOCAL enable_seqscan = off`) confirms that PostgreSQL selects `Index Scan using idx_sales_medicine_sold_on` with exact composite `Index Cond` pushdown—the plan chosen automatically once `sales` grows to production scale.

**Live PostgreSQL 18.6 `EXPLAIN (ANALYZE, COSTS)` Output:**

```text
-- 1. Default planner setting on 8-row single-page table:
 Seq Scan on sales  (cost=0.00..1.14 rows=3 width=22) (actual time=0.018..0.020 rows=3.00 loops=1)
   Filter: ((sold_on >= '2026-05-10'::date) AND (sold_on <= '2026-05-12'::date) AND (medicine_id = 1))
   Rows Removed by Filter: 5
   Buffers: shared hit=1

-- 2. With SET LOCAL enable_seqscan = off (verifying Index Scan & composite Index Cond):
 Index Scan using idx_sales_medicine_sold_on on sales  (cost=0.13..8.20 rows=3 width=22) (actual time=0.082..0.084 rows=3.00 loops=1)
   Index Cond: ((medicine_id = 1) AND (sold_on >= '2026-05-10'::date) AND (sold_on <= '2026-05-12'::date))
   Index Searches: 1
   Buffers: shared hit=1 read=1
```

---

### (g) Scheduled Daily Sales Refresh (`pr_refresh_sales` & `pg_cron`) [6 marks]

`pr_refresh_sales(p_day)` aggregates `COALESCE(SUM(quantity), 0)` and `COALESCE(SUM(quantity * unit_price), 0.00)` from `sales` for `p_day` and upserts the summary into `daily_sales` using `ON CONFLICT (sales_date) DO UPDATE`. Rerunning the procedure for `2026-05-12` replaces the row deterministically without duplicating rows or double-counting revenue. Notice also that on `2026-05-12`, Amoxicillin's 7 units were rightly totalled at their historical sale snapshot price (`7 * 12.50 = 87.50`, plus `5 * 6.20 = 31.00` for Cetirizine = `118.50`) despite Amoxicillin's catalog price later rising to `13.00`.

```sql
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

-- Daily schedule at 00:15 for the previous day (CURRENT_DATE - 1):
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q01_daily_sales_refresh',
    '15 0 * * *',
    $$CALL q01_pharmacy.pr_refresh_sales(CURRENT_DATE - 1);$$
);
```

**Verified `daily_sales` Output (Before & After Rerun on `2026-05-12`):**

```text
 sales_date | total_qty | total_amount 
------------+-----------+--------------
 2026-05-10 |        16 |       125.00
 2026-05-11 |        22 |       181.25
 2026-05-12 |        12 |       118.50
 2026-05-13 |         0 |         0.00
(4 rows)

-- After second CALL pr_refresh_sales(DATE '2026-05-12'):
 sales_date | total_qty | total_amount 
------------+-----------+--------------
 2026-05-10 |        16 |       125.00
 2026-05-11 |        22 |       181.25
 2026-05-12 |        12 |       118.50
 2026-05-13 |         0 |         0.00
(4 rows)
```
