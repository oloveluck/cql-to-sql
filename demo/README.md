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
| `BreastScreeningDemo.sql` | the SQL, a CTE per CQL define |
| `run.rkt` | runs both sides and compares; `raco test demo/run.rkt` checks it |

**What is hand-written today:** the SQL. It is written in the shape the translator
(`translate.rkt`) is to generate: a CTE per define, the measurement period as parameters, the value
set as a table. Generating it (retrieves, properties, age, library defines) is the next step; the
comparison harness, the views and the reports are already the real thing.

**Why an Observation, not a Procedure:** `sql-on-fhir` reads resources against FHIR R6, where
Procedure's `performed[x]` became `occurrence[x]`, so a view cannot read it from R4 data.
BCS-E's numerator accepts a mammography Observation too.
