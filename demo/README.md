# Demo: one measure, two evaluators, the same MeasureReports

```sh
racket demo/run.rkt
```

A breast cancer screening measure shaped like HEDIS BCS-E's core (women 42–74 at the end of
2025, with a final/amended/corrected mammogram Observation during 2025), evaluated two ways:

1. **CQL, by the interpreter**: `BreastScreeningDemo.cql` run by `cql/measure`'s
   `evaluate-measure` → a MeasureReport per patient and a summary.
2. **SQL on FHIR**: the patients flattened by `views/patient.json` and `views/observation.json`
   (SQL-on-FHIR ViewDefinitions, run by `sql-on-fhir`) into SQLite tables, the value set as a
   `valueset_code` table, `BreastScreeningDemo.sql` run over them → one row per patient with a
   column per population → MeasureReports from the same report builder.

Every patient's MeasureReport and the summary must be identical; they are (13 of 13). Breaking
the SQL on purpose (age from 43) shows the comparison catching it on the boundary patient and the
summary.

| File | What |
|---|---|
| `BreastScreeningDemo.cql`, `FHIRHelpers.cql` | the measure logic |
| `measure.json` | the FHIR Measure (proportion, one group: initial population, denominator, numerator) |
| `valueset-mammography.json` | a two-code stand-in for NCQA's licensed Mammography value set |
| `patients/` | 12 patients, one per outcome: numerator, no mammogram, too young, male, mammogram in 2023, not final, wrong code, second code system, ages 74/75/42/41 on the last day |
| `views/` | the ViewDefinitions |
| `BreastScreeningDemo.sql` | the SQL (SQLite), a CTE per CQL define |
| `BreastScreeningDemo.postgres.sql` | the same for PostgreSQL / Aidbox's `sof` schema |
| `aidbox-load.json` | a transaction bundle: the patients, the views, and their `$materialize` |
| `run.rkt` | runs both sides and compares; `raco test demo/run.rkt` checks it |

## In Aidbox (PostgreSQL)

`BreastScreeningDemo.sql` is SQLite (`:named` parameters, `strftime`, `julianday`); in Aidbox use
`BreastScreeningDemo.postgres.sql`, the same CTEs in PostgreSQL over the `sof` schema. Tested on
PostgreSQL 16: the same 12 rows, with typed (`date`, `timestamptz`) or all-text view columns.

1. Load the patients and the two ViewDefinitions, and materialize them as `sof.patient` and
   `sof.observation`, in one request: `POST /fhir` with `aidbox-load.json` (a transaction
   bundle; the last two entries call `ViewDefinition/…/$materialize` with type `view`).
2. Paste `BreastScreeningDemo.postgres.sql` into the DB console (or `POST /$sql`).

If `$materialize` rejects `getReferenceKey(Patient)`, change the observation view's `patient_id`
path to `subject.reference`; the query strips a leading `Patient/` either way.

**What is hand-written today:** the SQL. It is written in the shape the translator
(`translate.rkt`) is to generate: a CTE per define, the measurement period as parameters, the value
set as a table. Generating it (retrieves, properties, age, library defines) is the next step; the
comparison harness, the views and the reports are already the real thing.

**Why an Observation, not a Procedure:** `sql-on-fhir` reads resources against FHIR R6, where
Procedure's `performed[x]` became `occurrence[x]`, so a view cannot read it from R4 data.
BCS-E's numerator accepts a mammography Observation too.
