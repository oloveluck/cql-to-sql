# The relational model

FHIR data as relational tables, built for what a measure's cohort definition reads (HEDIS BCS-E
first). The tables are SQL-on-FHIR ViewDefinitions over FHIR R6, so the same definitions build them
in SQLite (here) and in any SQL-on-FHIR engine (Aidbox `$materialize`, Pathling).

```sh
racket model/build.rkt --out model.db <files or directories>          # JSON, Bundles, NDJSON
racket model/build.rkt --out model.db --zone-offset -07:00 <inputs>   # data with zone-less dateTimes
racket model/requirements.rkt BCSE_Details-2025.3.0.bundle.json       # what the measure reads, and coverage
racket model/spec.rkt                                                 # regenerate views/ and SCHEMA.md
raco test tests/model-test.rkt                                        # the whole check over two corpora
```

| File | What |
|---|---|
| `spec.rkt` | The model as data: tables, their source paths, the flattening rules; generates the ViewDefinitions |
| `views/` | The 86 generated ViewDefinitions (JSON), usable in any SQL-on-FHIR engine |
| `SCHEMA.md` | The generated data dictionary: every table, column, type and FHIRPath |
| `r4-to-r6.rkt` | The R4 → R6 conversion of the elements that changed, lossless (inverse included) |
| `repair.rkt` | Opt-in repair of invalid values the CQL interpreter tolerates |
| `build.rkt` | Data in, SQLite out, with indexes; reports anything not loaded |
| `check.rkt` | The "nothing lost" check: round trip, and every column against an independent walk of the data |
| `requirements.rkt` | The elements a measure's ELM reads, with cardinality, and which no table covers |

## The rules

- One table per resource type (`patient`, `claim`, `encounter`, …), a child table per repeating
  element (`claim_item`, `claim_item_product_or_service_coding`, …): every column one value.
- Every row carries its resource's key (`claim_id`, …), `patient_id` for patient data, and
  `<level>_idx` per repeating level, so it traces back to its source record.
- References become `<name>_id` columns; a Period `<name>_start`/`_end`; a choice element one
  column per type (`performed_datetime`, `performed_start`, `performed_end`).
- Dates stay ISO text as written: CQL compares at the precision written (`1965` is not
  `1965-01-01`).
- Statuses and negations stay (`status`, `verification_status`, `status_reason` codings): a
  stopped or entered-in-error mammogram is a row with that status, never silently a mammogram.
- Extensions: `<base>_extension` (url and value by type) and `<base>_extension_part` (nested).
- `data_source`: the HEDIS data-source tag (administrative or supplemental).
- Indexes on the resource key, `patient_id`, and `(system, code)` of every coding table.

## R4 data, R6 model

The data and the CQL are R4; the model is R6. `r4-to-r6.rkt` converts what changed, keeping R4
values R6 has no place for in HL7's cross-version extensions (`r6->r4` restores the original exactly):

| R4 | R6 / model |
|---|---|
| `Encounter.class` (Coding) | `class` (CodeableConcept list): `encounter_class_coding` |
| `Encounter.period` | `actualPeriod`: `encounter.period_start/end` |
| `Encounter.status` `finished` / `arrived`, `triaged` / `onleave` | `completed` / `in-progress` / `on-hold`; the R4 code in `encounter.status_r4` when R6 merged it |
| `Encounter.diagnosis.condition`, `.rank` | `condition` (CodeableReference), rank in an extension: `encounter_diagnosis.condition_id`, `.rank` |
| `Encounter.participant.individual` | `actor`: `encounter_participant.practitioner_id` |
| `Procedure.performed[x]` | `occurrence[x]`: `procedure.performed_*` |
| `Procedure.outcome`, `reasonCode`, `reasonReference` | `outcome`, `reason` (CodeableReference) |
| `MedicationDispense.medication[x]`, status `stopped` | `medication` (CodeableReference), `unfulfilled` |
| `Medication.amount` | `packageSize.amountPerItem`: `medication.amount_*` |
| `Claim.patient`, `ExplanationOfBenefit.patient` | `subject`: `patient_id` |

**For the CQL → SQL translator:** column names are version-neutral, but codes R6 changed must be
mapped: CQL's `Encounter.status = 'finished'` is `encounter.status = 'completed'` (or
`status_r4 = 'finished'`), MedicationDispense `'stopped'` is `'unfulfilled'`.

## Repairs

The view engine drops values that are not valid FHIR; the CQL interpreter reads the raw JSON and
copes. Two repairs, counted in the build report, keep the model from silently losing them:
zone-less dateTimes get `--zone-offset` (the interpreter gives them the evaluation's offset), and
`"true"`/`"false"` strings in boolean fields become booleans. Without `--zone-offset` the check
reports such values instead.

## Status

| Corpus | Resources | Rows | Columns equal to the data | Repairs |
|---|---|---|---|---|
| BCS-E test population, n = 1,000 (`bcse_usqc_testdata_n1000.zip`) | 11,770 | 31,064 | 309 / 309 | none |
| BCS-E scenarios, 19 members on the HEDIS core profiles (`scenarios/bcse`, built by SUSHI) | 88 | 111 | 309 / 309 | none |
| eCQM test patients (cql's vendored corpus) | 267 | 895 | 309 / 309 | 253 dateTimes, 1 boolean |

R4 → R6 → R4 round trip: lossless on all three. The scenarios need a build first:
`racket scripts/install-hedis.rkt`, `cd scenarios/bcse && npx fsh-sushi build .`, install-hedis
again; the model test skips them until then. `requirements.rkt` over BCSE_Details: 143 elements
read, all covered by the model.

## Example

```sql
-- members with a mammogram procedure from 2023-10-01 to the end of 2025, by status
SELECT p.status, count(DISTINCT p.patient_id) AS members
FROM procedure p
JOIN procedure_code_coding c ON c.procedure_id = p.procedure_id
WHERE c.code IN ('77065', '77066', '77067', '71651007')
  AND COALESCE(p.performed_datetime, p.performed_start) BETWEEN '2023-10-01' AND '2025-12-31T23:59:59'
GROUP BY p.status;
-- completed 293, entered-in-error 2, stopped 2 (n = 1,000)
```

(Comparing dates as text is only right when precisions match; the translator compares at the
precision CQL requires.)
