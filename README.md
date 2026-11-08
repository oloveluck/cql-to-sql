# cql-to-sql

Translate a CQL Library, such as a quality measure's logic, into one SQL query over tables built by
[SQL on FHIR](https://sql-on-fhir.org) ViewDefinitions, and check that the query gives the same answer
as the CQL interpreter.

> **Status: highly experimental, not fully tested.** A research prototype. The translator covers a
> subset of CQL, has been checked end to end on one small demo measure and on HL7's CQL expression
> suite, and has not been run on a real measure. Do not use it to report a quality measure.
> [TESTING.md](TESTING.md) says what is and isn't verified.

## How it works

```
FHIR resources ──ViewDefinitions──▶ tables          CQL ──▶ ELM ──translate──▶ SQL
                                       └──────── run the SQL (SQLite) ◀─────────┘
                                                        │
                                      one row per patient, a column per population
                                                        │
                                       MeasureReports, compared with the interpreter's
```

The data is flattened into tables, one per resource type, each row carrying `patient_id`, with the
value set expansions as a table. The logic is compiled to ELM by [`cql`](https://github.com/oloveluck/cql),
and each ELM node becomes a SQL fragment; a Library becomes one `WITH` query, a CTE per `define`.
Anything without a SQL translation is refused, never approximated.
[docs/translation.md](docs/translation.md) has the exact rules.

## Quickstart

```racket
#lang racket
(require cql-to-sql/library db json)

(define measure (call-with-input-file "demo/measure.json" read-json))
(define sql (cql->sql (file->string "demo/BreastScreeningDemo.cql") #:measure measure))
;; the SQL carries :period_start and :period_end; bind them, run it over the demo's tables, then
;; (sql-result->measure-reports measure headers rows "2025-01-01" "2025-12-31")
```

`racket demo/run.rkt` does all of it: it builds the tables, runs the SQL and the interpreter, and
compares the MeasureReports.

## Setup

```sh
for r in fhir fhirpath cql sql-on-fhir cql-to-sql; do git clone https://github.com/oloveluck/$r.git; done
raco pkg install --no-docs --link --auto --batch fhir/fhir fhir/fhir-spec fhirpath cql sql-on-fhir cql-to-sql
raco test -p cql-to-sql
```

`PLAN.md` holds the plan and design decisions; `model/` and `demo/` have their own READMEs.

License: MIT. The repo root carries NCQA's HEDIS MY2025 BCS-E bundles, value sets and core IG package
as uploaded for this work; HEDIS content is NCQA's, and whether it may stay in a public repo is an open
question in `PLAN.md`.
