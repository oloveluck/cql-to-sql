# Plan

Mission: run CQL with the interpreter, translate the same CQL to SQL over SQL-on-FHIR
ViewDefinition tables, and check that the results are the same.

Hackathon context: we work in this repo (oloveluck/cql-to-sql) together with Owen. Pull often,
keep commits small, follow the conventions in `../fhir/CLAUDE.md` and `../cql/CLAUDE.md` (HTDP
style, `contract-out`, `module+ test` in every module, floors that only rise).

The process as it works today (retargeting the data through ViewDefinitions, translating the ELM
to one SQL query, the oracles, the limits) is written up in `docs/translation.md`; this file is
the plan and the decisions behind it.

## Hackathon demo (`demo/`, done)

Two hours left, so a thin end-to-end slice instead of the phases below: a BCS-E-shaped measure
(women 42–74, a mammogram Observation in 2025), 12 hand-made patients, a two-code test value set,
two hand-written ViewDefinitions, and the measure's SQL written by hand in the translator's
target shape. `racket demo/run.rkt` builds MeasureReports from the interpreter and from SQLite
and compares them: 13 of 13 identical (12 individual + summary). Decisions taken for it: SQLite
only (Aidbox optional, views only), hand-written views and SQL, synthetic value set, "the same"
= equal MeasureReports. See `demo/README.md`. Afterwards: generate the views and the SQL
(phases 4–6), then BCS-E.

## Next: BCS-E over a relational model

**Where we are:** the measure runs against FHIR data. The interpreter evaluates BCSE_Details over
the 19 scenario Bundles and agrees with 19/19 score keys (see "BCS-E scenarios" below).
**Goal:** run the same measure against a relational model holding the same data, and get the same
patient cohort and MeasureReports. **We design the model ourselves**, as SQL-on-FHIR
ViewDefinitions over **FHIR R6** data. The cohort definition (the measure's population criteria)
says which patient fields the model needs (R1); then how to flatten FHIR into it (R2). The
measure's CQL is then translated to SQL over that model (R5); its result is itself a relational
table, the patient cohort (R5). Everything runs locally first (SQLite); Aidbox comes after it
works end to end.

```
FHIR data ──ViewDefinitions (R1–R2)──▶ relational model (tables)
                                              │ SQL translated from the CQL (R5)
                                              ▼
                                     cohort table: patient × group × population
                                              │ aggregate
                                              ▼
                                     MeasureReports ── compared with the interpreter's and the score keys
```

**Status: the relational model (R1–R4) is built** — `model/`, see `model/README.md`:
- **R1** `model/requirements.rkt` reads the measure's ELM: 143 elements BCS-E reads, each with its
  R4 cardinality; all covered by the model (a test keeps it so).
- **R2** `model/spec.rkt` declares the model and generates **86 ViewDefinitions** (`model/views/`)
  and a data dictionary (`model/SCHEMA.md`): normalized child tables, R6 paths, keys, positions,
  statuses and negations, extensions, data source.
- **R3** `model/r4-to-r6.rkt` (lossless, with its inverse) and `model/build.rkt` (data → SQLite,
  indexed). Loaded: the 1,000-member BCS-E population (11,770 resources, 31,064 rows), the 19
  BCS-E scenarios (88 resources: NCQA coverage codes, the LTI extension, claims, procedures; built
  by `install-hedis.rkt` + `npx fsh-sushi build`) and the eCQM test patients.
- **R4** `model/check.rkt`: R4 → R6 → R4 round trip lossless on all three corpora; all 309
  columns equal an independent walk of the data on all three. It found that the view engine drops invalid
  FHIR values the interpreter tolerates (zone-less dateTimes, `"true"` strings in the eCQM data):
  `model/repair.rkt` repairs them, opt-in and counted.
- `tests/model-test.rkt` runs all of it (about 5 s).
- **Next: R5**, the CQL translated to SQL over these tables, producing the cohort table.

### R1. What the model must contain: the fields the cohort definition reads

The model needs exactly what the cohort definition (the CQL behind the population criteria)
reads; anything else is optional. A first pass over the
measure's ELM (a script over the bundles' `application/elm+json`, approximate: properties reached
through function operands may be missing) gives 14 resource types:

| Resource | Elements BCS-E reads |
|---|---|
| Patient | birthDate, gender, deceased[x], communication (language, preferred), extension (sex parameter for clinical use, race/ethnicity) |
| Coverage | period, type, extension (inhospice, lti, orec, lishist) |
| Claim | id, type, billablePeriod, careTeam (sequence, provider), diagnosis (sequence, diagnosis, type), procedure (sequence, procedure), supportingInfo (sequence, category, code), item (productOrService, modifier, revenue, serviced[x], location[x], quantity, diagnosisSequence, procedureSequence, informationSequence) |
| ExplanationOfBenefit | as Claim, plus outcome and item.adjudication (category, amount) |
| Encounter | id, status, class, type, period, diagnosis (condition, rank), participant (individual) |
| Procedure | id, status, code, performed[x], bodySite, outcome, encounter, reasonReference |
| Condition | id, code, onset[x], abatement[x] |
| Observation | id, status, code, effective[x], value[x] |
| DiagnosticReport | id, status, code, effective[x] |
| MedicationDispense | status, medication[x], whenHandedOver, daysSupply, quantity |
| Medication | id, code, amount |
| Practitioner | id, identifier (system, value) |
| PractitionerRole | id, practitioner, code, specialty, extension |
| Location | id, identifier, type |

Plus the common shapes: CodeableConcept → coding (system, code); Period (start, end); Reference
(reference); Identifier (system, value); Quantity/Money (value); Extension (url, value);
`meta.tag` (the HEDIS data source: administrative vs. supplemental).

Plus the **negation and status fields** (missing from the first pass; see "Prior art", the OHDSI
lesson): the measure and the test data depend on records of things *not* done or not valid —
`status` (stopped, entered-in-error, cancelled, preliminary), `Condition.verificationStatus`
(refuted), ServiceRequest/MedicationRequest `doNotPerform`, Procedure/Observation `statusReason`,
and the QI-Core/USQC "not done" extensions (notDoneReason, notDoneValueSet). A model that drops
them silently counts a declined mammogram as a mammogram.

- **Task:** make this a tool, `requirements.rkt`: walk the ELM (cql/elm/ast, from our compiler)
  and list per resource type the element paths read, including through function operands. Its
  output is the model's contract; rerun it for any other measure.
- **The tool records each path's cardinality** (0..1 vs. 0..*) from the ModelInfo, because
  cardinality decides column vs. child table (R2): FHIRPath-to-SQL needs it (sql-on-fhir
  discussion #69). With it, the flattening is generated, not hand-decided.

### R2. How to flatten: the rules (decided: child tables)

One table per resource type with its single-valued elements as columns, plus a rule for repeating
elements (Claim.item, codings, diagnoses, …). Two options:

- **(a) Normalized child tables:** one table per repeating element, keyed by the parent id and
  the element's position, e.g. `claim`, `claim_item`, `claim_item_product_or_service (claim_id,
  item_index, system, code)`, `claim_diagnosis`, `coverage`, `patient`. A true relational model;
  value set matching is a join. BCS-E needs roughly 30 tables.
- **(b) One row per resource, repeating elements as JSON columns** (`collection: true`): about 14
  tables, list logic in JSON functions; matches the translator's JSON encoding of lists.

**Decided: (a) normalized child tables.** (This revises the JSON-columns recommendation from
the demo planning, made before the goal was a relational model.) Reasons:
- It is the relational model asked for: every table is flat, every column one value, so analysts
  and tools (DB console, BI) read it without JSON functions.
- Portable: plain joins work the same in SQLite, DuckDB and PostgreSQL/Aidbox. JSON functions
  differ per engine (`json_each` vs. `jsonb_array_elements`, …): the demo already hit the
  SQLite/PostgreSQL split.
- The measure's dominant pattern, "a code of this element is in a value set", is a join of a
  child table with the value set table, indexable, and the translator emits it as `EXISTS`.
- SQL-on-FHIR builds child tables natively: a ViewDefinition per table, `forEach` over the
  repeating element, the parent's id and `%rowIndex` as the key.
- The cost, ~30 tables instead of ~14, is generated, not hand-written (from R1).
Every child table also carries `patient_id`, so per-patient filtering never needs a join up to
the parent. Either way the rules are:
- References become `<name>_id` columns (`getReferenceKey()`), e.g. `patient_id`, `claim_id`.
- A choice element becomes one column per type used: `performed_datetime`, `performed_start`,
  `performed_end`.
- A Period becomes `<name>_start` and `<name>_end`.
- Dates stay ISO text, not SQL `date`/`timestamp`: CQL compares at the precision written (a
  birthDate of `1960` is not `1960-01-01`).
- Each extension BCS-E reads becomes a named column, selected by its url (e.g.
  `coverage.in_hospice`).
- `meta.tag` (data source) becomes a column, since HEDIS logic distinguishes administrative from
  supplemental data.
- Each table is a SQL-on-FHIR ViewDefinition, generated from R1 by these rules, so the same
  definitions produce the tables in SQLite (sql-on-fhir) and in Aidbox (`$materialize`).
- **Lineage:** every row carries its source resource's id (and, in a child table, the element's
  position), so a cohort difference leads back to the FHIR record behind it (the FHIR-to-OMOP
  lineage practice).
- **Indexes for the retrieve:** `patient_id` on every table, `(system, code)` on every coding
  table, and the date columns. CQL's retrieve is designed around exactly these access paths
  (code and date), so the generated SQL's filters hit them.

### R3. Load the 19 scenarios into the model

- Locally: the scenario Bundles → R4 → R6 conversion → the generated ViewDefinitions
  (`sql-on-fhir`) → SQLite.
- Aidbox: deferred until everything works locally (then `$materialize` the same ViewDefinitions;
  see phase 3).
- **The model is R6** (decided). The scenarios, the HEDIS profiles and the measure's CQL are R4
  (FHIR 4.0.1), so the data is converted R4 → R6 before flattening, and the ViewDefinitions use
  R6 paths. Column names stay version-neutral (`performed_start` whichever path fills it).
  Checked against the R4 and R6 core packages (elements and status code systems), these changed;
  the rest of what the model reads did not:

  | R4 | R6 |
  |---|---|
  | `Encounter.class` (Coding, 0..1) | `class` (CodeableConcept, 0..*) |
  | `Encounter.period` | `actualPeriod` |
  | `Encounter.status` `finished`, `arrived`, `triaged`, `onleave` | `completed`, `in-progress`, `in-progress`, `on-hold` (R4 code kept when merged) |
  | `Encounter.diagnosis.condition` (Reference) | `condition` (CodeableReference, 0..*) |
  | `Encounter.diagnosis.rank` | removed (kept in the cross-version extension) |
  | `Encounter.participant.individual` | `actor` |
  | `Procedure.performed[x]` | `occurrence[x]` |
  | `Procedure.outcome` (CodeableConcept) | `outcome` (CodeableReference, 0..*) |
  | `Procedure.reasonCode` / `reasonReference` | `reason` (CodeableReference) |
  | `MedicationDispense.medication[x]`, status `stopped` | `medication` (CodeableReference), `unfulfilled` |
  | `Medication.amount` (Ratio) | `packageSize.amountPerItem` (Ratio); `totalVolume` was R5 only, gone in R6 |
  | `Claim.patient`, `ExplanationOfBenefit.patient` | `subject` |

  The first version of this table missed the status codes, the Claim/EOB `patient` rename and
  R6's removal of `totalVolume`; building the model found them.
- **R4 → R6 conversion (done, `model/r4-to-r6.rkt`):** a targeted converter for these fields,
  lossless (R4 values without an R6 place go into HL7's cross-version extensions; its inverse
  restores every resource of both corpora exactly); HL7's cross-version StructureMaps through
  Owen's `fml` package later, for everything else. `sql-on-fhir` is R6 already, so local flattening then
  works as is. The interpreter keeps reading the R4 originals: the comparison also tests that the
  conversion lost nothing the measure needs.
- **The translator maps CQL's R4 paths to the model's columns**, never to R6 paths: the model is
  the contract between the two.
- Aidbox and R6 (deferred): whether it holds R6 data, or takes the locally built tables.

### R4. Check that the flattening loses nothing the measure needs

Before any SQL, prove the tables hold the data: for every R1 path and every scenario, the values
FHIRPath reads from the Bundle equal the values in the tables (count, value, precision). A path
with no column, or a value lost (a second coding, a partial date), shows up here, not as a wrong
rate later.

### R5. The measure in SQL over the model: the patient cohort, then MeasureReports

- **Translate the CQL to SQL on FHIR:** SQL for BCSE_Details over the model's tables, packaged as a
  SQL-on-FHIR SQLView Library (its `relatedArtifact`s name the ViewDefinitions it depends on, by
  table label). Generated by the translator (phases 4–5), or hand-written for one population
  first (initial population: age, gender, enrollment, product line), the way `demo/` did.
- **Compilation scheme: population-level, keyed by `patient_id`.** Not one query per patient:
  every define compiles to a relation over all patients that carries `patient_id` (a Boolean
  define is the set of patients for whom it is true; a list define is rows with `patient_id`),
  each define a view (or CTE) and a reference to it a `SELECT … FROM` that view, so a library is
  a graph of views. Every join includes `patient_id` (the patient context made explicit). The
  ELM → SQL mapping follows the "Prior art" table below.
- **The cohort is a table in the model (decided):** the SQL's result is one row per patient per
  Measure.group (BCS-E: general and Medicare), with the proportion-scoring subset rules applied.
  Named after OHDSI's cohort table convention (`cohort_definition_id, subject_id,
  cohort_start_date, cohort_end_date`) so OHDSI-style tooling can read it:
  `cohort (cohort_definition_id = measure|group, subject_id, cohort_start_date = period start,
  cohort_end_date = period end, initial_population, denominator, denominator_exclusion,
  numerator)`. Why a table, not only reports: a comparison names the patient and population that
  differ; MeasureReports are aggregates of it, so they cannot disagree with it; "in the
  denominator, not in the numerator" is a care-gap list, one query; stratifiers (SES, age, race,
  ethnicity) are columns added later.
- **The interpreter's cohort in the same shape:** its per-patient populations
  (`measure-group-populations`) written as rows of the same table, so the two cohorts compare
  row by row (`EXCEPT` both ways is empty) and a difference names the patient and population.
- **MeasureReports** aggregate the cohort (counts per group, measureScore) with `cql/measure`'s
  report builder, compared with the interpreter's and with the 19 score keys (phase 6). Floor
  that only rises.
- **Across engines:** later, the same views and SQL must give the same cohort in SQLite and in
  PostgreSQL/Aidbox, the way the SQL on FHIR paper validated Pathling/Spark against
  Aidbox/PostgreSQL.

### Prior art and design principles

What others did when compiling CQL (or similar cohort logic) to a relational model, and what we
take from it.

| Source | What it is | What we take |
|---|---|---|
| Bryn Rhodes (CQL spec editor), [CQL technical implementation webinar](https://ecqi.healthit.gov/sites/default/files/Jul23-CQL-Technical-Implementation-Webinar-Transcript.pdf) (2019) | CQL constructs and their SQL equivalents; a .NET ELM → SQL translator (Healthy Decisions) translated a chlamydia screening measure to SQL over OMOP | The ELM → SQL mapping below; population-level SQL; retrieves designed for indexes |
| OHDSI, [CQL on OMOP](https://www.ohdsi.org/wp-content/uploads/2023/08/Aug1-OMOP-on-CQL-on-FHIR-dQM-Cohort-Evaluation_OHDSI-Community-Call_8-31-23.pdf) (2023) | NCQA HEDIS digital measures run against OMOP at an HL7 Connectathon | Our scenario. Main problem: OMOP has no negated events, while the measures rely on them, so our model keeps them (R1). Value sets need mapping to the model's codes |
| OHDSI Circe / ATLAS | Cohort definitions (JSON) compiled to SQL, writing a standard cohort table | The cohort table convention (R5) |
| [FunSQL](https://github.com/MechanicalRabbit/FunSQL.jl) (OHDSI, Julia) | SQL built compositionally from small fragments | Keep building SQL as an AST (`sql/ast.rkt`), one fragment per ELM node, never by string templates |
| Pathling (CSIRO), [SQL on FHIR paper](https://www.nature.com/articles/s41746-025-01708-w) | FHIRPath → Spark SQL; the same views and SQL run on two engines and compared | Cross-engine validation (R5) |
| [sql-on-fhir discussion #69](https://github.com/FHIR/sql-on-fhir-v2/discussions/69) | FHIRPath → SQL by walking the expression tree | Cardinality decides UNNEST vs. column: record it in R1 |
| [Vulcan FHIR-to-OMOP IG](https://build.fhir.org/ig/HL7/fhir-omop-ig) (HL7) | Mapping FHIR resources to relational OMOP tables | Choosing among several codes, keeping statuses, lineage to the source resource (R2) |
| Eugene Vestel, [CQL to SQL conversion](https://www.youtube.com/watch?v=RlfmuHvDbsw) (SQL on FHIR conference 2025) | A CQL → SQL proof of concept over SQL-on-FHIR views | Closest to our setup; little public detail |

**The ELM → SQL mapping** (from the webinar; translate the ELM, where the compiler has already
reduced CQL's timing phrases to a few primitives):

| CQL / ELM | SQL |
|---|---|
| `define` | a view (or CTE); a reference is `SELECT … FROM` it |
| Retrieve `[Encounter: "VS"]` | the table, `EXISTS`/`JOIN` against `value_set_codes(name, system, code)` |
| `with` / `without` | `EXISTS` / `NOT EXISTS` (semi-join, anti-join) |
| multi-source `from` | `CROSS JOIN` |
| `let` | `LATERAL` (`OUTER APPLY` in T-SQL) |
| `First` / `Last` | window functions (`ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY …)`) |
| union of different types | outer union: shared columns, NULLs elsewhere, `COALESCE` downstream |
| interval-valued element | two columns, `_start` and `_end` |
| timing (`during`, `before`, `overlaps`) | inline comparisons of the boundaries, or SQL functions |
| precision (`day of`) | the comparison truncated to that precision |
| patient context | `patient_id` on every relation and in every join (population-level) |

**Principles we adopt:**
1. Population-level SQL keyed by `patient_id`, not per-patient evaluation (R5).
2. One view per define; the library is a graph of views (SQL-on-FHIR SQLViews), and the engine
   decides inline, view or materialized.
3. Indexes on `patient_id`, `(system, code)` and dates, the retrieve's access paths (R2).
4. Negated events and statuses are part of the model (R1).
5. Cardinality from the ModelInfo decides column vs. child table; flattening is generated (R1).
6. Precision is the hard part: dates keep their written precision (R2), and the test data
   checks it (a month-precision mammogram counts, a year-precision one does not).
7. The cohort table follows OHDSI's convention (R5).
8. Every row traces back to its source resource (R2).
9. SQL built as an AST, one fragment per ELM node (FunSQL's lesson).
10. The same cohort from every engine (R5).

## Target measure: HEDIS MY2025 Breast Cancer Screening (BCS-E)

Uploaded to the repo root (2e22c7f): `BCSE_Details-2025.3.0.bundle.json` and
`BCSE_Reporting-2025.3.0.bundle.json` (Measure + 43 Libraries, CQL and ELM), the measure's visual
flow diagram (PDF), and the HEDIS Core IG package (`ncqa.hedis.core.main.v2025-2025.1.0.tar`; its
extracted `package/` is ignored by git).

- Initial population: women 42–74, continuously enrolled with a medical benefit, Medicare /
  Commercial / Medicaid / Exchange product line. Exclusions: death, hospice, bilateral mastectomy,
  gender-affirming chest surgery with gender dysphoria, palliative care, I-SNP/LTI, frailty with
  advanced illness. Numerator: a mammogram from October 1 two years before the period to its end.
- Reads Patient, Coverage, Claim, ExplanationOfBenefit, Encounter, Procedure, Condition,
  Observation, DiagnosticReport, MedicationDispense: the Synthea data in Aidbox and our
  ViewDefinitions must cover the claims and coverage resources, not only clinical ones.
- **Compiles and runs in the `cql` interpreter** after the parser fixes in `../cql` (below): all 44
  libraries compile; `raco cql BCSE_Details.cql --data <dir> --valuesets <dir> --libraries <dir>`
  evaluates the populations.
- **Missing: the NCQA value sets** (~224 referenced, none in the bundles; NCQA's Value Set
  Directory is licensed). Without them, value set membership is an error, so only patients whose
  data never reaches a value set check evaluate.
- **Licensing to confirm:** HEDIS content is NCQA's; this repo is public and MIT. Confirm the
  bundles and PDF may be published, or move them out of the repo (and its history).

### MeasureReport fixes in `../cql` (uncommitted there)

- **Every group:** `measure-populations` merged all groups' criteria into one lookup, so BCS-E's
  Medicare group overwrote the general group's, and the report had one group. Now
  `measure-group-populations` evaluates each group and the MeasureReport has a group per
  Measure.group (its id and code carried over, each scored on its own counts).
  `measure-populations` is the first group's.
- **Measurement period parameter:** `evaluate-measure` passed `"Measurement Period"`, BCS-E
  declares `"Measurement period"` (so the CQL silently used its default), and as `Interval<Date>`,
  not DateTime. The parameter is now found by name without case and given the declared type.
- BCS-E's `evaluate-measure` returns both groups (summary and individual). All `cql` tests pass:
  469 (8 new), HL7 suite 1820/1823, eCQM 71/76.

### Parser fixes in `../cql` (pushed, 2b846aa)

The BCS-E libraries exposed misparses where brag, which has no greediness, closed an open term
early. The grammar now has a closed and an `-open` form per precedence level, so a query or an
if-then-else is only ever the rightmost operand and the parse is unique:
- `if c then x else L.f(y)` parsed as `(if c then x else L).f(y)`.
- `… else (xs) i where i > 1` and `exists (Q) a where P or R` closed the where clause early (a
  silent wrong answer when the rest did not reference the alias).
- `distinct (xs) s sort by …`, `flatten (Q) items."f"(p)`, `x in (rs) r return …`: a query as
  the operand of distinct/flatten and membership.
- `sort by "Interval"()`: a fluent function in `sort by` applies to the row (`$this`).
- `raco cql f.cql --libraries dir` ignored `--libraries` when only compiling; includes now resolve.

Results: HL7 CQL suite 1820/1823 (unchanged), ELM corpus 769/803 ELM-equal (was 766, floor
raised), eCQM 71/76 (unchanged), 461 unit tests (8 new).

## Setup (done)

All paths are relative to this repo's root; the dependencies are cloned next to it.

- Racket 9.3: `brew install minimal-racket` (in a Rosetta shell on Apple silicon, prefix with
  `arch -arm64`).
- Dependencies, cloned as siblings of this repo:
  `for r in fhir fhirpath cql sql-on-fhir; do git clone https://github.com/oloveluck/$r.git ../$r; done`
- Install, from this repo's root:
  `raco pkg install --no-docs --link --auto --batch ../fhir/fhir ../fhir/fhir-spec ../fhirpath ../cql ../sql-on-fhir .`
- Test: `raco test -p cql-to-sql`.
- SQL TCK report: `racket tests/tck.rkt -v`.

## Status

| Piece | Status |
|---|---|
| Run CQL with the interpreter (`cql`) | Done: `load-runtime-library`, `rlib-value`, `measure-populations`; 1820/1823 on the HL7 suite |
| Expression → SQL, checked against the interpreter | `translate.rkt`, `tests/tck.rkt`; 902 pass, 4 known fail, 875 untranslatable, 42 skip (floor raised from 866) |
| Whole Library / Measure → SQL | Done: `library.rkt` (`cql->sql`, `translate-library`, CTE dependency DAG, population proportion query) |
| Test data | Available in `cql/tests/vendor/ecqm/`: 4 measures, 76 patient cases, 57 value sets, FHIRHelpers |
| HEDIS BCS-E in the interpreter | Compiles and runs (after the `../cql` parser fixes); NCQA value sets missing |
| FHIR → ViewDefinition → rows | In memory only (`sql-on-fhir/view`'s `eval-view`) |
| Rows into SQLite / DuckDB | Done (`model/build.rkt`) |
| ViewDefinitions for the resources measures read | Done (`model/spec.rkt`) |
| Retrieve, value sets, FHIR properties in SQL | Done (`library.rkt`, `translate.rkt`) |
| Whole libraries in SQL (defines, refs, functions, FHIRHelpers, parameters) | Done (`library.rkt`) |
| Per-patient comparison SQL vs. interpreter | Done: verified 13/13 matching MeasureReports via `library.rkt` test and `demo/run.rkt` |
| MeasureReport from the interpreter | Done: `evaluate-measure`, a report group per Measure.group, the measurement period parameter by its declared name and type |
| MeasureReport from SQL | Done (phase 6) |
| Running the SQL in Aidbox (cloud, PostgreSQL) | Missing: REST connector and PostgreSQL dialect |

Most common untranslatable constructs in the SQL TCK: `elm-timing` (464), `elm-between` (54),
`+`/`-` on Any (65), Expand, Intersect, Except, aggregate clause, `elm-minmax`, ToDateTime,
Collapse, AnyTrue/AllTrue, Today.

## Phases

0. **BCS-E end to end in the interpreter.** Get the NCQA value sets; ViewDefinitions and Synthea
   test data in Aidbox covering Coverage, Claim and ExplanationOfBenefit; patients that land in
   each population (initial population, each exclusion, numerator), so the comparison is not
   vacuous. This is the measure the later phases translate.
1. **Expression coverage for what measures use.** Timing operators (before, during, overlaps,
   in), between, date/time arithmetic, interval set operations, Today/ToDateTime. Raise the TCK
   floor with each step.
2. **Data layer.** ViewDefinitions for Patient, Encounter, Condition, Observation, Procedure,
   MedicationRequest and the other types the eCQMs retrieve; load FHIR JSON → `eval-view` →
   SQLite tables; value set expansions into a `valueset_code(url, system, code)` table. Check:
   sql-on-fhir's shared suite (144 tests) gives the same rows from SQLite as in memory.
   Risk: sql-on-fhir parses against R6, the test data is R4; R4-only elements may be dropped.
   Independent of `translate.rkt`, so a good parallel task.
3. **Aidbox connector (cloud, over REST).** Aidbox stores FHIR in PostgreSQL and implements
   SQL on FHIR: a ViewDefinition plus
   [`$materialize`](https://www.health-samurai.io/docs/aidbox/modules/sql-on-fhir/operation-materialize)
   becomes a table or view in the `sof` schema. Our instance is in the cloud, so everything goes
   over REST rather than a direct Postgres connection:
   - `POST /fhir/ViewDefinition/$materialize` with the Phase 2 ViewDefinitions → `sof.*` tables.
   - `POST /fhir` (transaction bundle) to load test patients; value set codes into a table.
   - `POST /$sql` to run the translated SQL; results come back as JSON.
   - **PostgreSQL dialect** in `sql/dialect.rkt`: `jsonb_build_array`/`jsonb_build_object`/
     `jsonb_array_elements`/`jsonb_agg`, a real boolean type (types.rkt encodes Boolean as 0/1),
     typed view columns (`date`, `timestamptz`, `boolean`) cast to our encodings at the table
     boundary, `$1` positional parameters in `sql/print.rkt`, and a way to raise runtime errors.
   - Credentials from the environment (`AIDBOX_URL`, `AIDBOX_CLIENT_ID`, `AIDBOX_CLIENT_SECRET`),
     never in the repo; Aidbox tests skip when they are unset, so `raco test` works offline.
   - Requires Aidbox 2508+ in fhir-schema mode. First step is a smoke check: version, `SELECT 1`
     through `$sql`, materialize and query one small view.
   - Bonus check: Aidbox's `sof.*` rows equal `eval-view`'s rows for the same data.
   SQLite stays the fast local oracle; Aidbox is a second place the same SQL must give the same
   answer.
4. **Retrieve and properties.** `[Condition: "VS"]` → select on the view table joined to the
   value set table, filtered to the current patient; property paths → view columns; FHIRHelpers
   calls → direct SQL. Check with small hand-written libraries against the interpreter.
5. **Whole libraries.** Defines as CTEs, references and functions inlined, Measurement Period
   as a query parameter; one query, one row per patient, a column per define.
6. **MeasureReport from SQL, compared with the interpreter's.** Both sides produce a FHIR
   MeasureReport for the same measure, period and patients, and the reports must be equal:
   - The SQL's per-patient rows (a column per population define) become an `individual`
     MeasureReport per patient and a `summary` one (counts per group, measureScore). Counts can be
     computed in SQL (`SUM(CASE …)`) or, in Aidbox, the report built in SQL (`jsonb_build_object`)
     so `$sql` returns it directly.
   - The population rules and the report shape are the interpreter's, reused rather than
     re-implemented: `cql/run`'s `measure-group-populations` (IP; denominator ⊆ IP; exclusion ⊆
     denominator; numerator ⊆ denominator minus exclusions) and `cql/measure`'s report builder.
     Then a difference is a difference in the populations, never in the assembly.
   - Reference side: `cql/measure`'s `evaluate-measure` (summary, or `#:subject` for individual).
   - Compare per patient and in summary, in SQLite and in Aidbox, for BCS-E and the eCQM corpus;
     floor that only rises, named known mismatches.
   - Not yet: stratifiers (BCS-E has SES, Age, Race, Ethnicity), non-proportion scoring.
7. **Wrap-up.** DuckDB dialect, output as SQL-on-FHIR SQLQuery/SQLView Library, `ig/` with
   `Library/$cql-to-sql`.

## BCS-E scenarios (HEDIS, measurement year 2025)

NCQA's HEDIS core IG (`ncqa.hedis.core.main.v2025-2025.1.0.tar`) and the BCS-E measure bundles
(`BCSE_Details`/`BCSE_Reporting-2025.3.0.bundle.json`) are at the repo root, as uploaded.
`scenarios/bcse` holds test members for the measure: a FSH project on the HEDIS core profiles.
- **19 scenarios**, one per path through the measure:
  - numerator by claim and by Observation, including the window's first day and the day before it;
  - not screened;
  - age 41, 42 on the last day, and 75;
  - male;
  - an enrollment gap and a late enrollment start;
  - bilateral, left + right, and left-only mastectomy;
  - hospice, palliative care, deceased;
  - Medicare screened, and Medicare long-term care, which only the Medicare group excludes.
- **Score keys:** each scenario is a Bundle with an NCQA-style `<id>.scorekey` Parameters giving
  the expected value of every population define (`Initial population`, `Exclusion`, `Denominator`,
  `Numerator`, and the `- Medicare` forms). The values come from the measure's CQL, not from an
  interpreter run.
- **Value sets:** test-only stand-ins (`scripts/standin-valuesets.rkt`) for the 167 NCQA value
  sets the CQL declares. Real codes are used where a scenario reaches a set, and a placeholder
  that matches nothing elsewhere. Results with them test the logic, not a HEDIS rate.
- **Setup:** `racket scripts/install-hedis.rkt` puts the package where SUSHI and fsh look. fsh's
  copy is repackaged with `<resourceType>-<id>.json` names, or the family's package index sees no
  HEDIS profile. Run one `sushi build scenarios/bcse` first, so its dependencies are cached.
- **Status:**
  - The scenarios build with SUSHI (0 errors) and with fsh, identically (256/256 resources).
  - They validate against the HEDIS + CARIN BB profiles: `racket scripts/bcse-check.rkt`, 89
    examples, 0 invalid.
  - `tests/bcse-scenarios-test.rkt` checks that, and that every score key is consistent.
  - **The measure runs:** with cql at upstream `5b4e5b2` (Niko's parser fixes), all 43 BCS-E
    libraries compile, and the interpreter's BCSE_Details agrees with **19/19** score keys (the
    test's floor). With an older cql the test says how many libraries compile and skips this.
  - 13 stand-ins carry test codes: mammography, the three mastectomies, hospice and palliative
    care, medical insurance, the four payer coverage types, professional/institutional claims, and
    final observation status (`final`, `amended`, `corrected`).
- **Demo:** `racket demo/bcse/run.rkt` prints the funnel per member and the rates, and writes the
  MeasureReports (`demo/bcse/README.md`).
- **Population demo:** `racket demo/bcse/population.rkt` runs the measure over the n=1000 US
  Quality Core export (`bcse_usqc_testdata_n1000.zip`), with a Coverage adapter (SOPT payer type
  to HEDIS coverage type, medical benefit ActCode MCPOL, open periods closed at the export date).
  - With NCQA's MY2025 value sets (`2025.3.0.zip`, `scripts/ncqa-valuesets.rkt`; the stand-ins are
    now only the fallback), 892/1000 agree with its answer key: 36.1% against 60.9%.
  - Every other member has a traced cause. 91 of them are mammograms recorded only as a Procedure,
    which HEDIS's numerator doesn't read.
  - `--supplemental` (those Procedures also sent as results, a labelled what-if) gives 60.4% and
    983/1000.
  - `demo/bcse/ANSWER-KEY-FINDINGS.md` writes the key's errors up for the data's author.
  - It also writes an interactive report and an animated walkthrough.
- **Through a FHIR server:** `racket demo/bcse/server.rkt` loads the population, the Measure, its
  Libraries and NCQA's value sets into fhir-server's store through `POST /` (27 s for 11,770
  resources), then calls `Measure/$evaluate-measure`.
- **Next:** the same Bundles and score keys feed the relational model work ("Next: BCS-E over a
  relational model", R1–R5) and phase 6, the per-patient SQL vs. interpreter comparison.
- **Found on the way, for the shared repos (not patched here):**
  - fsh fails on an integer literal inside a parameterized RuleSet
    (`regexp-replace*: contract violation … given: 1`; worked around in `rulesets.fsh`).
  - fsh writes `compose: {}` for a ValueSet with no rules, where SUSHI writes none.
  - **cql (for Niko):** property access on a System.Quantity returns null: `(45 days).value` and
    `(45 days).unit` are null. HEDIS's "Has valid gaps in coverage" reads both, so any member with
    an allowed coverage gap fails continuous enrollment (3 members in the n=1000 population).
    The fix is one clause in `eval-property` (interp.rkt): `[(fp-quantity? v) (case path [("value")
    (fp-quantity-value v)] [("unit") (fp-quantity-unit v)] [else cql-null])]`. Tested in a scratch
    checkout: agreement rises from 894 to 896.
    On the HEDIS-shaped population (`bcse_hedis_n1000_bulkfhir_aidbox_loaded.zip`,
    `demo/bcse/hedis-population.rkt`) it matters far more: short gaps between plan years are common
    there. Without the fix: 177 eligible, 40/85 screened (47.1%). With it: 338 eligible, 100/200
    (50.0%).
  - **cql (for Niko), performance:** over a data source such as fhir-server's store,
    `cql/measure`'s `include-resolver` is slow for every patient. For every include it:
    - fetches all Libraries from the source (`libraries`);
    - base64-decodes and re-parses the CQL;
    - misses the compile cache, which is keyed by AST identity.

    So BCS-E's 43 libraries are re-parsed and recompiled per patient, about a minute each, and
    `$evaluate-measure` over 1,000 members takes hours. Caching the parse by CQL text helps but isn't
    enough; the Library list needs caching per evaluation too.
  - `fhir/sd/sd-index` finds conformance resources only by `StructureDefinition-*.json`-style file
    names, so a package with other names (NCQA's) is invisible to fsh and the validator, and
    validation then passes by failing open.

## Open questions

- What counts as "the same": the SQL's cohort equals the interpreter's, row by row, and so do
  the MeasureReports aggregated from them (R5, phase 6). Comparing with expected results (the 19
  BCS-E score keys, the eCQM MeasureReports) is a separate check of the interpreter.
- Which CQL matters most: BCS-E is the target now; the eCQM corpus stays as a second test set.
- Decided: we design the relational model ourselves; its fields come from the cohort definition
  (R1); normalized child tables (R2); FHIR R6, with the R4 data converted (R3); the cohort result
  is a table in the model (R5); local first, Aidbox after everything works.
- Where do the NCQA value sets come from, and may they be stored in Aidbox / the repo?
- Licensing of the uploaded NCQA files in this public repo.
- Division of phases between team members and Owen.
- Aidbox (deferred until everything works locally): R6 data or locally built tables; a shared
  or dedicated instance; which Client may call `$sql` and `$materialize`.
