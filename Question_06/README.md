# Question 6: Monthly Payroll Processing (50 Marks)

- **Course:** ICT371 Advanced Database
- **Student Name:** Hope Nsana
- **Student ID:** `202402859`
- **Database Schema:** `q06_payroll`
- **Verified Engine:** PostgreSQL 18.6 (`x86_64-windows`)
- **Files:** [`solution.sql`](./solution.sql) | [`output.txt`](./output.txt)

---

## Problem Summary

In this academic payroll model:
- $\text{gross\_pay} = \text{basic\_salary} + \text{allowance}$
- $\text{net\_pay} = \text{gross\_pay} - \text{deduction}$
- Existing payroll records are retained unchanged when a payroll month is processed again, and historical payroll records remain visible in reports even after an employee becomes inactive.

---

## (a) Database Schema and Seed Data [6 marks]

### Design Highlights
- **`employees`**: `employee_id` (PK), `full_name`, non-negative `NUMERIC(12,2)` columns (`basic_salary`, `allowance`, `deduction` each constrained by `CHECK (... >= 0)`), and `active BOOLEAN NOT NULL DEFAULT TRUE`.
- **`payroll`**: `payroll_id` (PK), `employee_id` (FK -> `employees`), `pay_month DATE NOT NULL CHECK (pay_month = date_trunc('month', pay_month)::date)` enforcing first-of-month dates (`YYYY-MM-01`), non-negative `gross_pay` and `net_pay`, and `CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)`.
- **`salary_audit`**: `audit_id` (PK), `employee_id` (FK -> `employees`), `old_salary`, `new_salary`, and `changed_at TIMESTAMPTZ`.
- **Seed Data:**
  - 5 seeded employees: 3 active (`Mulenga Kapwepwe`, `Thandiwe Lungu`, `Chilufya Mutale`) and 2 inactive (`Mwamba Sichone`, `Natasha Kalaba`).
  - Payroll seeded across **two months** (`2026-01-01` and `2026-02-01`), including a `2026-01-01` historical payroll record for `Mwamba Sichone` (`employee_id = 4`) prior to becoming `active = FALSE`.

---

## (b) Function: `fn_net_pay(p_employee_id)` [6 marks]

```sql
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic_salary NUMERIC(12,2);
    v_allowance    NUMERIC(12,2);
    v_deduction    NUMERIC(12,2);
    v_net_pay      NUMERIC(12,2);
BEGIN
    IF p_employee_id IS NULL THEN
        RAISE EXCEPTION 'Employee ID cannot be NULL.';
    END IF;

    SELECT e.basic_salary, e.allowance, e.deduction
      INTO v_basic_salary, v_allowance, v_deduction
      FROM employees e
     WHERE e.employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: % does not exist.', p_employee_id;
    END IF;

    v_net_pay := v_basic_salary + v_allowance - v_deduction;

    IF v_net_pay < 0 THEN
        RAISE EXCEPTION 'Computed net pay (%) for employee_id % cannot be negative.',
            v_net_pay, p_employee_id;
    END IF;

    RETURN v_net_pay;
END;
$$;
```

### Verification Summary
- Accurately computes `basic_salary + allowance - deduction` for all seeded employees (e.g., `15000 + 2500 - 1800 = 15700.00`).
- Rejects unknown employee ID (`999`), `NULL` employee ID, and negative computed net pay (`2000 + 200 - 2500 = -300.00`) via `RAISE EXCEPTION`.

---

## (c) Procedure: `pr_process_payroll(p_month DATE)` [8 marks]

```sql
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_emp       RECORD;
    v_gross_pay NUMERIC(12,2);
    v_net_pay   NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'Invalid pay_month (%). Must be a non-null month-start date (YYYY-MM-01).', p_month;
    END IF;

    FOR v_emp IN
        SELECT e.employee_id, e.basic_salary, e.allowance, e.deduction
          FROM employees e
         WHERE e.active = TRUE
         ORDER BY e.employee_id
    LOOP
        IF NOT EXISTS (
            SELECT 1
              FROM payroll p
             WHERE p.employee_id = v_emp.employee_id
               AND p.pay_month = p_month
        ) THEN
            v_gross_pay := v_emp.basic_salary + v_emp.allowance;
            v_net_pay   := fn_net_pay(v_emp.employee_id);

            INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
            VALUES (v_emp.employee_id, p_month, v_gross_pay, v_net_pay)
            ON CONFLICT (employee_id, pay_month) DO NOTHING;
        END IF;
    END LOOP;
END;
$$;
```

### Verification Summary
1. **Active-Only Query `FOR` Loop:** `CALL pr_process_payroll(DATE '2026-03-01')` inserts rows for active employees (`1, 2, 3`) and skips inactive employees (`4, 5`).
2. **Existing Rows Retained Unchanged on Rerun:** After adding active Employee `6` (`Kelvin Mwanza`) and changing Employee `1`'s allowance (`2500.00` -> `2800.00`), rerunning `CALL pr_process_payroll(DATE '2026-03-01')` leaves Employee `1`'s existing `2026-03-01` row untouched at `17500.00 / 15700.00` while inserting only missing Employee `6` (`16000.00 / 14500.00`).
3. **Date Validation:** Rejects non-month-start dates (`2026-03-15`) and `NULL`.
4. **Atomic Rollback on Invalid Net Pay:** When a temporary active employee with excessive deduction (`net_pay = -400.00`) is encountered mid-loop during `2026-04-01`, `fn_net_pay` raises an exception and rolls back all earlier loop inserts (`april_rows_after_rollback = 0`).

---

## (d) Trigger: `trg_audit_salary_change` [8 marks]

```sql
CREATE OR REPLACE FUNCTION fn_trg_audit_salary_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_salary_change
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION fn_trg_audit_salary_change();
```

### Verification Summary
- Updating Employee `1`'s `basic_salary` from `15000.00` to `16500.00` logs exactly 1 audit record (`old_salary = 15000.00, new_salary = 16500.00`).
- Updating `allowance` (`Employee 2`), updating `basic_salary` to the same value (`12000.00` -> `12000.00`), and updating `deduction` (`Employee 5`) produce **zero** additional audit entries.

---

## (e) View: `v_payroll_report` [5 marks]

```sql
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    p.payroll_id,
    e.employee_id,
    e.full_name,
    e.active AS currently_active,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e
  ON e.employee_id = p.employee_id;
```

### Verification Summary
Because `v_payroll_report` joins `payroll` to `employees` on `employee_id` **without** filtering `WHERE e.active = TRUE`, historical payroll rows for employees who later became inactive are preserved:
```text
 payroll_id | employee_id |    full_name     | currently_active | pay_month  | gross_pay | net_pay
------------+-------------+------------------+------------------+------------+-----------+----------
          1 |           1 | Mulenga Kapwepwe | t                | 2026-01-01 |  17500.00 | 15700.00
          2 |           2 | Thandiwe Lungu   | t                | 2026-01-01 |  13500.00 | 12300.00
          3 |           3 | Chilufya Mutale  | t                | 2026-01-01 |  21000.00 | 18800.00
          4 |           4 | Mwamba Sichone   | f                | 2026-01-01 |  11000.00 | 10100.00
...
```

---

## (f) Index and `EXPLAIN` Plan [5 marks]

```sql
CREATE INDEX idx_payroll_pay_month
    ON payroll (pay_month);
```

### Justification (Avoiding Duplication of `UNIQUE (employee_id, pay_month)`)
- The existing `UNIQUE (employee_id, pay_month)` constraint automatically builds a composite B-tree index with **`employee_id` as the leading column** and `pay_month` as the trailing second column.
- That composite index is optimal for per-employee lookups (`WHERE employee_id = ? AND pay_month = ?`), which `pr_process_payroll` already uses.
- However, a cross-company monthly payroll report filters **only** on `WHERE pay_month = DATE '2026-01-01'` across **all** employees, omitting the leading `employee_id` key.
- Creating `idx_payroll_pay_month ON payroll(pay_month)` places `pay_month` as the single leading B-tree column for direct equality/range seeks by month, without duplicating `(employee_id, pay_month)` or `(pay_month, employee_id)`.

### Matching Query & Verified PostgreSQL 18.6 `EXPLAIN` Output
*(With `SET enable_seqscan = off` on the small seed table to verify index selection; reset immediately afterward)*:
```sql
EXPLAIN (COSTS OFF)
SELECT employee_id, pay_month, gross_pay, net_pay
  FROM payroll
 WHERE pay_month = DATE '2026-01-01';
```
```text
                    QUERY PLAN
---------------------------------------------------
 Index Scan using idx_payroll_pay_month on payroll
   Index Cond: (pay_month = '2026-01-01'::date)
(2 rows)
```

---

## (g) Scheduled Job & Job History Inspection [6 marks]

### 1. Schedule `pr_process_payroll` for `02:00` on the 1st of Every Month (`0 2 1 * *`)
Passing the first date of the **previous month**:
```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q06_monthly_payroll',
    '0 2 1 * *',
    $$CALL q06_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);$$
);
```

### 2. Inspect Registered Job Definition (`cron.job`)
```sql
SELECT jobid, jobname, schedule, command, active
  FROM cron.job
 WHERE jobname = 'q06_monthly_payroll';
```

### 3. Inspect Job Run History (`cron.job_run_details`)
```sql
SELECT jobid, runid, status, return_message, start_time, end_time
  FROM cron.job_run_details
 WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q06_monthly_payroll')
 ORDER BY start_time DESC
 LIMIT 10;
```

### Local Windows PostgreSQL 18.6 Environment Note
- Neither `pg_cron` nor `pgAgent` is installed on this Windows PostgreSQL 18.6 server.
- In [`solution.sql`](./solution.sql), the exact scheduled command `CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);` is executed twice directly against PostgreSQL 18.6 (producing 4 previous-month rows with zero duplicates on rerun), and `cron.schedule(...)` is guarded by a `pg_available_extensions` check so the script completes with exit code `0`.
