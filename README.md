# cql-to-sql

Translate CQL Libraries into SQL over relational tables built by
[SQL on FHIR](https://sql-on-fhir.org) ViewDefinitions.

A CQL Library (or a Measure's Library) plus ViewDefinitions for the FHIR resource types it
retrieves becomes a SQL-on-FHIR **SQLQuery** or **SQLView** Library. The query returns one row per
patient, with a column per selected define (a Measure's populations). SQLite is the first
dialect and runs in-process for testing; DuckDB is the second.

Status: early. The translator is being built against two oracles: the HL7 CQL test suite
(each expression translated, run in SQLite, compared with the expected result) and the eCQM
corpus (per-patient populations equal to the interpreter's).

The package also defines a FHIR Implementation Guide (in `ig/`, authored in FSH): the
`Library/$cql-to-sql` operation, the CqlSqlQuery/CqlSqlView profiles, and the extensions
that bind view columns to CQL properties.

Builds on the Racket packages [`cql`](https://github.com/oloveluck/cql) (CQL → ELM, interpreter)
and [`sql-on-fhir`](https://github.com/oloveluck/sql-on-fhir) (ViewDefinitions).

## Quickstart & Usage

```
CQL Measure ──(cql->sql)──▶ SQL Query ──(execute in DB)──▶ Population Rows ──(sql-result->measure-reports)──▶ MeasureReports
```

### 1. Translate a CQL Measure to SQL

Compile a `.cql` file and FHIR `Measure` JSON using `cql->sql` (from `cql-to-sql/library`):

```racket
#lang racket
(require cql-to-sql/library
         json)

(define cql-text (file->string "demo/BreastScreeningDemo.cql"))
(define measure (call-with-input-file "demo/measure.json" read-json))

;; Generates CTEs + population SELECT query
(define query-sql (cql->sql cql-text #:measure measure))
```

The generated SQL has the following structure:
```sql
WITH
age_at_end_of_period AS (...),
initial_population AS (...),
denominator AS (...),
mammograms_during_period AS (...),
numerator AS (...)
SELECT ip.patient_id AS patient_id,
       ip.v AS "initial-population",
       d.v AS "denominator",
       (d.v AND n.v) AS "numerator"
FROM initial_population AS ip
JOIN denominator AS d ON d.patient_id = ip.patient_id
JOIN numerator AS n ON n.patient_id = ip.patient_id
ORDER BY ip.patient_id ASC;
```

### 2. Execute the Query in your Database

Run the query in SQLite, DuckDB, or PostgreSQL (over tables built from SQL-on-FHIR ViewDefinitions):

```racket
(require db)

(define conn (sqlite3-connect #:database "path/to/db.sqlite"))

;; Bind parameters (e.g. measurement period)
(define bound-sql
  (regexp-replace* #px":([a-z_]+)" query-sql
                   (hash "period_start" "'2025-01-01T00:00:00.000Z'"
                         "period_end"   "'2025-12-31T23:59:59.999Z'")))

(define result (query conn bound-sql))
(define headers (map (lambda (h) (cdr (assq 'name h))) (rows-result-headers result)))
(define rows (rows-result-rows result))
```

The database returns one row per patient:
```
patient_id        | initial-population | denominator | numerator
------------------+--------------------+-------------+-----------
p01-numerator     | 1                  | 1           | 1
p02-no-mammogram  | 1                  | 1           | 0
p03-too-young     | 0                  | 0           | 0
```

### 3. Generate `MeasureReport`s from SQL Results

Use `sql-result->measure-reports` to build standard FHIR `MeasureReport` JSON objects:

```racket
;; Returns both individual reports per patient (hash) and the cohort summary report:
(define-values (individual-reports summary-report)
  (sql-result->measure-reports measure headers rows "2025-01-01" "2025-12-31"))

;; Or get an individual report for a specific patient:
(define patient-report
  (sql-result->measure-reports measure headers rows "2025-01-01" "2025-12-31" #:subject "Patient/p01-numerator"))
```

## Testing

```sh
raco pkg install --link --auto cql-to-sql
raco test -p cql-to-sql
```

MIT licensed.
