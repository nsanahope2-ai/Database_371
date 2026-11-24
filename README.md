# ICT371 Advanced Database — Complete Solutions (Questions 1–10)

- **Course:** ICT371 Advanced Database
- **Student Name:** Hope Nsana
- **Student ID:** `202402859`
- **Database Engine Verified On:** PostgreSQL 18.6 (`x86_64-windows`, `psql` 18.6 & `pgAdmin 4`)

---

## Local PostgreSQL Environment Notes

1. **Installed Software:**
   - **PostgreSQL Server 18.6** (`postgresql-x64-18` service on `localhost:5432`)
   - **`psql` 18.6** command-line client and **pgAdmin 4**
2. **Scheduler Extensions (`pg_cron` / `pgAgent`):**
   - Neither `pg_cron` (a Unix/Linux background-worker extension not bundled with Windows PostgreSQL 18 installers) nor `pgAgent` is installed on the local Windows PostgreSQL 18.6 instance.
   - Accordingly, every question's **Part (g)** defines and tests the idempotent summary/batch refresh procedure directly on PostgreSQL 18.6 (including repeated-run verification to prove no duplication or double-counting) and provides the standard **`pg_cron`** job registration (`cron.schedule(...)`) wrapped in an extension-availability guard so every `solution.sql` executes end-to-end with zero errors on Windows PostgreSQL 18.6.
3. **Query Planner & `EXPLAIN` Plans (`Part (f)`):**
   - On small 6-row seed tables that fit inside a single 8 KB heap page, PostgreSQL's cost-based optimizer naturally prefers a single-page `Seq Scan` under default settings. Each script runs `ANALYZE` and demonstrates `EXPLAIN` with `enable_seqscan = off` (resetting it immediately afterward) to verify that PostgreSQL selects and uses the created index (`Index Scan` / `Bitmap Index Scan`) for the target predicate.

---

## Question Directory & Direct Links

| Question | Topic | Isolated Schema | Folder | SQL Script | Execution Output |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Question 1** | Pharmacy Stock and Daily Sales | `q01_pharmacy` | [Question_01](./Question_01/) | [solution.sql](./Question_01/solution.sql) | [output.txt](./Question_01/output.txt) |
| **Question 2** | University Fee Payments | `q02_university_fees` | [Question_02](./Question_02/) | [solution.sql](./Question_02/solution.sql) | [output.txt](./Question_02/output.txt) |
| **Question 3** | Library Returns and Overdue Fines | `q03_library` | [Question_03](./Question_03/) | [solution.sql](./Question_03/solution.sql) | [output.txt](./Question_03/output.txt) |
| **Question 4** | Clinic Appointment Scheduling | `q04_clinic` | [Question_04](./Question_04/) | [solution.sql](./Question_04/solution.sql) | [output.txt](./Question_04/output.txt) |
| **Question 5** | Hostel Room Allocation | `q05_hostel` | [Question_05](./Question_05/) | [solution.sql](./Question_05/solution.sql) | [output.txt](./Question_05/output.txt) |
| **Question 6** | Monthly Payroll Processing | `q06_payroll` | [Question_06](./Question_06/) | [solution.sql](./Question_06/solution.sql) | [output.txt](./Question_06/output.txt) |
| **Question 7** | Water Meter Readings and Billing | `q07_water_billing` | [Question_07](./Question_07/) | [solution.sql](./Question_07/solution.sql) | [output.txt](./Question_07/output.txt) |
| **Question 8** | Transport Fleet Maintenance | `q08_fleet` | [Question_08](./Question_08/) | [solution.sql](./Question_08/solution.sql) | [output.txt](./Question_08/output.txt) |
| **Question 9** | Farmer Cooperative Maize Deliveries | `q09_maize_coop` | [Question_09](./Question_09/) | [solution.sql](./Question_09/solution.sql) | [output.txt](./Question_09/output.txt) |
| **Question 10** | Scholarship Application Assessment | `q10_scholarship` | [Question_10](./Question_10/) | [solution.sql](./Question_10/solution.sql) | [output.txt](./Question_10/output.txt) |

---

## How to Run Any Question Locally

Using **pgAdmin 4 Query Tool** or **`psql`**:

```powershell
psql -h localhost -U postgres -d ict371_final -v ON_ERROR_STOP=1 -f Question_01/solution.sql
```

Each script is completely self-contained and idempotent (`DROP SCHEMA IF EXISTS ... CASCADE; CREATE SCHEMA ...;`).
