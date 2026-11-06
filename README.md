# cql-to-sql

Translate a CQL Library (a quality measure's logic) into one SQL query over relational tables
built by [SQL on FHIR](https://sql-on-fhir.org) ViewDefinitions, and check that the query gives the
same answer as the CQL interpreter.

> **Status: highly experimental, not fully tested.** This is a research prototype built in a
> hackathon and extended since. The translator covers a subset of CQL, has been checked end to end
> on one small demo measure (12 patients) and on the HL7 CQL expression suite, and has **not** been
> run on a real measure such as HEDIS BCS-E. Expect missing constructs (reported as
> "untranslatable" rather than as wrong SQL), unoptimised SQL, and interfaces that change without
> notice. Do not use it to report a quality measure.

Builds on the Racket packages [`cql`](https://github.com/oloveluck/cql) (CQL → ELM, the
interpreter, MeasureReports) and [`sql-on-fhir`](https://github.com/oloveluck/sql-on-fhir)
(ViewDefinitions and their evaluation), both part of the
[`fhir`](https://github.com/oloveluck/fhir) family.

## How it works

```
                 retarget the data                          translate the logic
FHIR resources ──ViewDefinitions──▶ relational tables      CQL text ──cql──▶ ELM ──translate.rkt──▶ SQL AST ──print──▶ SQL text
                                          │                                                              │
                                          └──────────────── run the SQL in SQLite ◀──────────────────────┘
                                                                     │
                                                 one row per patient, a column per population
                                                                     │
                                                 sql-result->measure-reports ──▶ MeasureReports
                                                                     │
                                                 compared with cql/measure's evaluate-measure
```

Two things happen, and they are independent until the SQL runs:

1. **Retargeting the data.** FHIR resources are flattened into tables by SQL-on-FHIR
   ViewDefinitions: one table per resource type, one row per coding where a code is read, every
   row carrying `patient_id`, and a `valueset_code(url, system, code)` table for the value set
   expansions. The translator's SQL is written against this table shape, so it is the contract
   between the two halves (see [Retargeting](docs/translation.md#retargeting-the-tables-the-sql-runs-over)).
2. **Translating the logic.** The CQL is parsed and compiled to ELM by the `cql` package. The
   translator never reads CQL text itself: it is a structural recursion over ELM (`translate.rkt`)
   that builds a SQL abstract syntax tree (`sql/ast.rkt`), one fragment per ELM node, with a CQL
   type on every fragment that decides how the value is encoded (native SQL scalar or JSON text).
   `library.rkt` turns a whole Library into one `WITH` query: a CTE per `define`, in dependency
   order, and a final `SELECT` keyed by `patient_id` with a column per Measure population.
   Anything the translator has no SQL for raises `exn:fail:untranslatable`; it never emits SQL that
   computes something else.

The whole process, stage by stage and with the exact rules, is in
[`docs/translation.md`](docs/translation.md).

## Quickstart

Translate the demo measure and run it in SQLite:

```racket
#lang racket
(require cql-to-sql/library db json)

(define cql-text (file->string "demo/BreastScreeningDemo.cql"))
(define measure  (call-with-input-file "demo/measure.json" read-json))

;; 1. CQL -> SQL text: a CTE per define and the population SELECT (SQLite dialect by default)
(define sql (cql->sql cql-text #:measure measure))

;; 2. Bind the measurement period. The SQL carries :period_start / :period_end as named
;;    parameters; nothing binds them for you. The demo substitutes literals:
(define bound
  (regexp-replace* #px":([a-z_]+)" sql
                   (lambda (_ name)
                     (format "'~a'" (hash-ref (hash "period_start" "2025-01-01T00:00:00.000Z"
                                                    "period_end"   "2025-12-31T23:59:59.999Z")
                                              name)))))

;; 3. Run it over tables in the shape the translator expects (demo/run.rkt builds them from
;;    demo/views/*.json with sql-on-fhir's view engine, plus valueset_code)
(define conn (sqlite3-connect #:database "demo.sqlite"))
(define result (query conn bound))
(define headers (map (lambda (h) (cdr (assq 'name h))) (rows-result-headers result)))
(define rows (rows-result-rows result))

;; 4. FHIR MeasureReports from the rows, built by cql/measure's own report builder
(define-values (individual-reports summary-report)
  (sql-result->measure-reports measure headers rows "2025-01-01" "2025-12-31"))
```

The generated SQL for the demo has this shape:

```sql
WITH age_at_end_of_period AS (SELECT p.id AS patient_id, … AS age FROM patient AS p),
     initial_population   AS (SELECT p.id AS patient_id, coalesce(…, 0) AS v FROM patient AS p JOIN age_at_end_of_period AS a ON …),
     denominator          AS (SELECT p.id AS patient_id, coalesce(ip.v, 0) AS v FROM patient AS p JOIN initial_population AS ip ON …),
     mammograms_during_period AS (SELECT DISTINCT o.patient_id AS patient_id, o.id AS id
                                  FROM observation AS o JOIN valueset_code AS vs ON (vs.url = '…' AND vs.system = o.code_system AND vs.code = o.code)
                                  WHERE …),
     numerator            AS (SELECT p.id AS patient_id, coalesce(EXISTS (SELECT 1 FROM mammograms_during_period AS m WHERE m.patient_id = p.id), 0) AS v FROM patient AS p)
SELECT ip.patient_id AS patient_id, ip.v AS "initial-population", d.v AS "denominator", (d.v AND n.v) AS "numerator"
FROM initial_population AS ip JOIN denominator AS d ON … JOIN numerator AS n ON …
ORDER BY ip.patient_id ASC
```

and the query returns one row per patient:

```
patient_id        | initial-population | denominator | numerator
------------------+--------------------+-------------+-----------
p01-numerator     | 1                  | 1           | 1
p02-no-mammogram  | 1                  | 1           | 0
p03-too-young     | 0                  | 0           | 0
```

`racket demo/run.rkt` runs the demo both ways (interpreter and SQL) and compares the reports.

## What is verified, and what is not

Verified by tests in this repo (`raco test -p cql-to-sql`), with floors that only rise:

| Check | Test | Last recorded result |
|---|---|---|
| Each expression of the HL7 CQL test suite, translated, run in SQLite, compared with the expected value as the interpreter evaluates it | `tests/tck-test.rkt` (`racket tests/tck.rkt -v` for the report) | 902 pass, 4 known failures (SQLite `REAL` is not a 28-digit CQL Decimal), 875 untranslatable, 42 skipped |
| The demo measure: the SQL generated by `cql->sql` and the hand-written `demo/BreastScreeningDemo.sql`, each run over 12 patients, give MeasureReports identical to the interpreter's | `library.rkt` (test submodule), `demo/run.rkt` | 13 of 13 identical (12 individual + summary) |
| The relational model (`model/`): every element BCS-E reads is covered; R4 → R6 conversion is lossless; every column equals an independent walk of the data on three corpora | `tests/model-test.rkt` | 309/309 columns on each corpus |
| The 19 BCS-E scenarios build, validate against the HEDIS profiles, and the **interpreter** agrees with every score key | `tests/bcse-scenarios-test.rkt` | 19/19 (interpreter only) |

Not done, and not claimed:

- **No real measure has been translated.** HEDIS BCS-E runs in the interpreter (`demo/bcse/`),
  not in SQL. The eCQM corpus is not a SQL oracle yet.
- **The translator and the relational model are not connected.** `translate.rkt` writes SQL
  against the demo's two hand-written views (`demo/views/`: `patient(id, …)`,
  `observation(id, patient_id, …, code_system, code)`); the 86 generated views in `model/views/`
  use a different shape (`observation_id`, codings in `observation_code_coding`). Pointing the
  translator at the model is the next step.
- **Dialects.** SQLite is the only dialect that is run. A DuckDB dialect table exists
  (`sql/dialect.rkt`) and prints, but no test executes it. There is no PostgreSQL dialect:
  `demo/BreastScreeningDemo.postgres.sql` is hand-written.
- **The IG's `Library/$cql-to-sql` operation is a definition only.** Nothing implements it, and
  there is no `raco cql-to-sql` command.
- **Coverage.** About 875 of the suite's expressions are untranslatable, mostly timing phrases
  with a precision (`before day of`, `overlaps`), `between` over non-intervals, interval set
  operations, the `aggregate` clause, `Today`, and `ToDateTime`. A retrieve filtered by a single
  Code (not a value set) is translated **without** the code filter; see the
  [known limits](docs/translation.md#known-limits).

## Repository map

| Path | What |
|---|---|
| `translate.rkt` | ELM → SQL AST, one clause per ELM node; the operator registry; `exn:fail:untranslatable` |
| `library.rkt` | a Library → CTEs in dependency order + the population query; `cql->sql`; `sql-result->measure-reports` |
| `types.rkt`, `decode.rkt` | the CQL types the translator tracks and their SQL encodings; a SQL result back as a CQL value |
| `sql/ast.rkt`, `sql/dialect.rkt`, `sql/print.rkt` | the SQL as data; the per-engine operations (SQLite, DuckDB); SQL text |
| `run.rkt` | one expression through SQLite, for the oracles |
| `tests/tck.rkt`, `tests/tck-test.rkt` | the HL7 CQL suite through SQL, and its floor |
| `model/` | the relational model for BCS-E: 86 generated ViewDefinitions, R4 → R6 conversion, SQLite builder, the "nothing lost" check (`model/README.md`) |
| `demo/` | the demo measure, interpreter vs SQL (`demo/README.md`); `demo/bcse/`: HEDIS BCS-E in the interpreter over three populations (`demo/bcse/README.md`) |
| `scenarios/bcse/` | 19 BCS-E test members as FSH on the HEDIS profiles, each with a score key |
| `scripts/` | HEDIS package install, NCQA and stand-in value sets, the Postman collection |
| `ig/` | the FHIR Implementation Guide (FSH): the `Library/$cql-to-sql` OperationDefinition, the CqlSqlQuery/CqlSqlView Library profiles, the column-binding extension — published to GitHub Pages by CI |
| `presentation/` | the slides on evaluating BCS-E |
| `PLAN.md` | the working plan, design decisions and prior art |

## Setup

Racket 8.x or later with the sibling packages installed from source. From a directory holding the
clones:

```sh
for r in fhir fhirpath cql sql-on-fhir cql-to-sql; do git clone https://github.com/oloveluck/$r.git; done
raco pkg install --no-docs --link --auto --batch fhir/fhir fhir/fhir-spec fhirpath cql sql-on-fhir cql-to-sql
raco test -p cql-to-sql          # the floors above; the BCS-E scenario checks need fsh and a SUSHI build
racket tests/tck.rkt -v          # the SQL TCK report, with the untranslatable constructs counted
racket demo/run.rkt              # the demo, both ways
```

`tests/bcse-scenarios-test.rkt` also needs the `fsh` package; see `demo/bcse/README.md` for the
HEDIS package and SUSHI steps the scenarios need.

## Licensing

MIT. The repo root carries NCQA's HEDIS MY2025 BCS-E bundles, value sets and core IG package as
uploaded for this work; HEDIS content is NCQA's, and whether it may stay in a public repo is an
open question in `PLAN.md`.
