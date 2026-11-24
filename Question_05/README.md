# Question 5: Hostel Room Allocation (50 Marks)

- **Course:** ICT371 Advanced Database
- **Student Name:** Hope Nsana
- **Student ID:** `202402859`
- **Database Schema:** `q05_hostel`
- **Verified Engine:** PostgreSQL 18.6 (`x86_64-windows`)
- **Files:** [`solution.sql`](./solution.sql) | [`output.txt`](./output.txt)

---

## Problem Summary

A university hostel allocates beds without exceeding room capacity. Each student may hold at most one `'ACTIVE'` allocation at a time, while `'ENDED'` allocations remain in the table as historical records and do not occupy beds.

---

## (a) Database Schema and Seed Data [6 marks]

### Design Highlights
- **`students`**: `student_id` (PK), `student_number` (`UNIQUE NOT NULL`), `full_name`.
- **`rooms`**: `room_id` (PK), `room_number` (`UNIQUE NOT NULL`), `capacity` (`CHECK (capacity > 0)`).
- **`allocations`**: `allocation_id` (PK), `student_id` (FK -> `students`), `room_id` (FK -> `rooms`), `allocated_on`, `released_on` (`NULL` when active), `status` (`CHECK (status IN ('ACTIVE', 'ENDED'))`), plus a composite lifecycle `CHECK` constraint:
  ```sql
  CONSTRAINT chk_allocations_status_dates CHECK (
      (status = 'ACTIVE' AND released_on IS NULL)
      OR (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
  )
  ```
- **`occupancy_snapshot`**: composite primary key `PRIMARY KEY (snapshot_date, room_id)` with FK to `rooms` and non-negative `occupied_beds` and `free_beds`.
- **Seed Categories Demonstrated:**
  - **`R-101` (Full):** Capacity `2`, `2` `ACTIVE` allocations + `1` historical `ENDED` allocation -> `0` free beds.
  - **`R-102` (Partly Occupied):** Capacity `3`, `1` `ACTIVE` allocation + `1` historical `ENDED` allocation -> `2` free beds.
  - **`R-103` (Empty — History Only):** Capacity `2`, `0` `ACTIVE` allocations + `1` historical `ENDED` allocation -> `2` free beds.
  - **`R-104` (Empty — Zero Allocation Rows):** Capacity `4`, literally `0` rows in `allocations` -> `4` free beds (explicitly proves `LEFT JOIN` handling for rooms with no allocations).
  - **Free Students:** Students `4` (`Luyando Tembo`) and `5` (`Kunda Zulu`) have no `ACTIVE` allocation and are used to test procedures and triggers.

---

## (b) Function: `fn_free_beds(p_room_id)` [6 marks]

```sql
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity     INT;
    v_active_count INT;
BEGIN
    IF p_room_id IS NULL THEN
        RAISE EXCEPTION 'Room ID cannot be NULL.';
    END IF;

    SELECT r.capacity
      INTO v_capacity
      FROM rooms r
     WHERE r.room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: % does not exist.', p_room_id;
    END IF;

    SELECT COUNT(*)::INT
      INTO v_active_count
      FROM allocations a
     WHERE a.room_id = p_room_id
       AND a.status = 'ACTIVE';

    RETURN v_capacity - v_active_count;
END;
$$;
```

### Verification Summary
- Seeded room results:
  - `R-101` (cap 2, 2 active, 1 ended) -> `0` free beds (`ENDED` row ignored).
  - `R-102` (cap 3, 1 active, 1 ended) -> `2` free beds (`ENDED` row ignored).
  - `R-103` (cap 2, 0 active, 1 ended) -> `2` free beds (`ENDED` row ignored).
  - `R-104` (cap 4, 0 rows) -> `4` free beds.
- `fn_free_beds(999)` and `fn_free_beds(NULL)` both raise explicit exceptions (`Unknown room_id: 999 does not exist.` / `Room ID cannot be NULL.`).

---

## (c) Procedure: `pr_allocate_room(p_student_id, p_room_id, p_allocated_on)` [8 marks]

```sql
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INT,
    p_room_id      INT,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_student_id IS NULL THEN
        RAISE EXCEPTION 'p_student_id cannot be NULL.';
    END IF;
    IF p_room_id IS NULL THEN
        RAISE EXCEPTION 'p_room_id cannot be NULL.';
    END IF;
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'p_allocated_on date cannot be NULL.';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: % does not exist.', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: % does not exist.', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations
         WHERE student_id = p_student_id AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE hostel allocation.', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full; no free beds available.', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;
```

### Verification Summary
1. **Valid Allocation:** `CALL pr_allocate_room(4, 2, DATE '2026-02-01')` allocates `Luyando Tembo` into `R-102` with `status = 'ACTIVE'` and `released_on = NULL`.
2. **Already-Active Student Rejected:** `CALL pr_allocate_room(1, 2, ...)` fails with `Student 1 already has an ACTIVE hostel allocation.`
3. **Full Room Rejected:** `CALL pr_allocate_room(5, 1, ...)` fails with `Room 1 is full; no free beds available.`
4. **Invalid Inputs Rejected:** Unknown `student_id` (`999`), unknown `room_id` (`999`), and `NULL` `p_allocated_on` all raise exceptions cleanly.

---

## (d) Trigger: `trg_enforce_allocation_rules` [8 marks]

```sql
CREATE OR REPLACE FUNCTION fn_trg_enforce_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity       INT;
    v_active_in_room INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT r.capacity
          INTO v_capacity
          FROM rooms r
         WHERE r.room_id = NEW.room_id
           FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Room ID % does not exist.', NEW.room_id;
        END IF;

        IF EXISTS (
            SELECT 1
              FROM allocations a
             WHERE a.student_id = NEW.student_id
               AND a.status = 'ACTIVE'
               AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)
        ) THEN
            RAISE EXCEPTION 'Trigger prevented SQL change: Student % already has an ACTIVE allocation.', NEW.student_id;
        END IF;

        SELECT COUNT(*)::INT
          INTO v_active_in_room
          FROM allocations a
         WHERE a.room_id = NEW.room_id
           AND a.status = 'ACTIVE'
           AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF v_active_in_room >= v_capacity THEN
            RAISE EXCEPTION 'Trigger prevented SQL change: Room % is at full capacity (% beds).', NEW.room_id, v_capacity;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_enforce_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_trg_enforce_allocation_rules();
```

### Verification Summary
- **Direct `INSERT` into full room (`R-101`):** Rejected (`Room 1 is at full capacity (2 beds)`).
- **Direct second `ACTIVE` `INSERT` for Student 1:** Rejected (`Student 1 already has an ACTIVE allocation`).
- **Direct `UPDATE` reactivating an `ENDED` row or moving an `ACTIVE` student into full `R-101`:** Rejected.
- **Self-Exclusion on `UPDATE`:** Updating `allocated_on` on Student 1's existing `ACTIVE` allocation inside already-full `R-101` succeeds (`UPDATE 1`) because `(TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)` excludes the row being updated from both the student-uniqueness check and the room-capacity count.
- **Ending an Allocation:** Updating `status = 'ENDED', released_on = DATE '2026-02-25'` succeeds cleanly.

---

## (e) View: `v_room_occupancy` [5 marks]

```sql
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id)::INT                AS occupied_beds,
    (r.capacity - COUNT(a.allocation_id))::INT AS free_beds
FROM rooms r
LEFT JOIN allocations a
  ON a.room_id = r.room_id
 AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;
```

### Live Query Result
```text
 room_id | room_number | capacity | occupied_beds | free_beds
---------+-------------+----------+---------------+-----------
       1 | R-101       |        2 |             2 |         0
       2 | R-102       |        3 |             2 |         1
       3 | R-103       |        2 |             0 |         2
       4 | R-104       |        4 |             0 |         4
(4 rows)
```
Note that placing `AND a.status = 'ACTIVE'` in the `LEFT JOIN` `ON` condition (rather than a `WHERE` clause) preserves both `R-103` (only `ENDED` allocations) and `R-104` (zero rows in `allocations`).

---

## (f) Partial Index and `EXPLAIN` Plan [5 marks]

```sql
CREATE INDEX idx_allocations_room_active
    ON allocations (room_id)
 WHERE status = 'ACTIVE';
```

### Justification
- Operational lookups in `fn_free_beds()`, the capacity trigger, and active room roster queries repeatedly filter `WHERE room_id = ? AND status = 'ACTIVE'`.
- Over multiple semesters, historical `'ENDED'` rows grow continuously while `'ACTIVE'` rows are bounded by physical bed count.
- A **partial B-tree index** on `(room_id) WHERE status = 'ACTIVE'` indexes only currently occupied beds, minimizing index storage, eliminating B-tree maintenance on historical `'ENDED'` rows, and directly answering active-bed lookups by `room_id`.

### Matching Query & Verified PostgreSQL 18.6 `EXPLAIN` Output
*(With `SET enable_seqscan = off` on the small seed table to demonstrate index selection; reset immediately afterward)*:
```sql
EXPLAIN (COSTS OFF)
SELECT allocation_id, student_id, room_id, allocated_on, status
  FROM allocations
 WHERE room_id = 1
   AND status = 'ACTIVE';
```
```text
                         QUERY PLAN
-------------------------------------------------------------
 Index Scan using idx_allocations_room_active on allocations
   Index Cond: (room_id = 1)
(2 rows)
```

---

## (g) Scheduled Job: `pr_refresh_occupancy()` at `23:55` Daily [6 marks]

```sql
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id)::INT                AS occupied_beds,
        (r.capacity - COUNT(a.allocation_id))::INT AS free_beds
    FROM rooms r
    LEFT JOIN allocations a
      ON a.room_id = r.room_id
     AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;
```

### `pg_cron` Daily `23:55` Registration
```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q05_nightly_occupancy_snapshot',
    '55 23 * * *',
    $$CALL q05_hostel.pr_refresh_occupancy();$$
);
```

### Verification & Local Windows PostgreSQL 18.6 Environment Note
- **Rerun / Upsert Verification:** `pr_refresh_occupancy()` was executed first (producing 4 snapshot rows for `CURRENT_DATE`, including empty rooms `R-103` and `R-104`), then Student 5 was allocated into `R-103` and `pr_refresh_occupancy()` was executed two more times on the same date. `occupancy_snapshot` retained exactly one row per `(snapshot_date, room_id)` (`4` rows total) with `R-103` updated in place from `(0, 2)` to `(1, 1)` and empty `R-104` preserved as `(0, 4)`.
- **Scheduler Note:** Because `pg_cron` and `pgAgent` are not installed on the local Windows PostgreSQL 18.6 instance, `solution.sql` wraps `cron.schedule(...)` inside a `pg_available_extensions` check so the script executes cleanly with exit code `0` while documenting the exact `55 23 * * *` schedule.
