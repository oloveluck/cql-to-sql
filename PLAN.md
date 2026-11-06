# Plan

Mission: run CQL with the interpreter, translate the same CQL to SQL over SQL-on-FHIR
ViewDefinition tables, and check that the results are the same.

Hackathon context: we work in this repo (oloveluck/cql-to-sql) together with Owen. Pull often,
keep commits small, follow the conventions in `../fhir/CLAUDE.md` and `../cql/CLAUDE.md` (HTDP
style, `contract-out`, `module+ test` in every module, floors that only rise).

A diagram of the target architecture will be added later; revise this plan to match it.

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

- **Task:** make this a tool, `requirements.rkt`: walk the ELM (cql/elm/ast, from our compiler)
  and list per resource type the element paths read, including through function operands. Its
  output is the model's contract; rerun it for any other measure.

### R2. How to flatten: the rules (decision needed)

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

### R3. Load the 19 scenarios into the model

- Locally: the scenario Bundles → R4 → R6 conversion → the generated ViewDefinitions
  (`sql-on-fhir`) → SQLite.
- Aidbox: deferred until everything works locally (then `$materialize` the same ViewDefinitions;
  see phase 3).
- **The model is R6** (decided). The scenarios, the HEDIS profiles and the measure's CQL are R4
  (FHIR 4.0.1), so the data is converted R4 → R6 before flattening, and the ViewDefinitions use
  R6 paths. Column names stay version-neutral (`performed_start` whichever path fills it).
  Checked against the R4 and R6 core packages, 10 of the elements BCS-E reads changed; Claim,
  ExplanationOfBenefit, Patient, Coverage, Condition and DiagnosticReport did not:

  | R4 | R6 |
  |---|---|
  | `Encounter.class` (Coding, 0..1) | `class` (CodeableConcept, 0..*) |
  | `Encounter.period` | `actualPeriod` |
  | `Encounter.diagnosis.condition` (Reference) | `condition` (CodeableReference, 0..*) |
  | `Encounter.diagnosis.rank` | removed (`use`) |
  | `Encounter.participant.individual` | `actor` |
  | `Procedure.performed[x]` | `occurrence[x]` |
  | `Procedure.outcome` (CodeableConcept) | `outcome` (CodeableReference, 0..*) |
  | `Procedure.reasonReference` | `reason` (CodeableReference) |
  | `MedicationDispense.medication[x]` | `medication` (CodeableReference) |
  | `Medication.amount` | `totalVolume` |

- **R4 → R6 conversion:** a targeted converter for these fields first (small, testable: every
  R1 value equal before and after); HL7's cross-version StructureMaps through Owen's `fml`
  package later, for everything else. `sql-on-fhir` is R6 already, so local flattening then
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
- **The cohort is a table in the model (decided):** the SQL's result is
  `cohort (group_id, patient_id, initial_population, denominator, denominator_exclusion,
  numerator)`, one row per patient per Measure.group (BCS-E: general and Medicare), with the
  proportion-scoring subset rules applied. Why a table, not only reports: a comparison names the
  patient and population that differ; MeasureReports are aggregates of it, so they cannot
  disagree with it; "in the denominator, not in the numerator" is a care-gap list, one query;
  stratifiers (SES, age, race, ethnicity) are columns added later.
- **The interpreter's cohort in the same shape:** its per-patient populations
  (`measure-group-populations`) written as rows of the same table, so the two cohorts compare
  row by row (`EXCEPT` both ways is empty) and a difference names the patient and population.
- **MeasureReports** aggregate the cohort (counts per group, measureScore) with `cql/measure`'s
  report builder, compared with the interpreter's and with the 19 score keys (phase 6). Floor
  that only rises.

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
- Test: `raco test -p cql-to-sql` (the README's `raco test cql-to-sql` does not work).
- SQL TCK report: `racket tests/tck.rkt -v`.

## Status (as of f98a58c)

| Piece | Status |
|---|---|
| Run CQL with the interpreter (`cql`) | Done: `load-runtime-library`, `rlib-value`, `measure-populations`; 1820/1823 on the HL7 suite |
| Expression → SQL, checked against the interpreter | Started: `translate.rkt`, `tests/tck.rkt`; 866 pass, 4 known fail, 911 untranslatable, 42 skip |
| Test data | Available in `cql/tests/vendor/ecqm/`: 4 measures, 76 patient cases, 57 value sets, FHIRHelpers |
| HEDIS BCS-E in the interpreter | Compiles and runs (after the `../cql` parser fixes); NCQA value sets missing |
| FHIR → ViewDefinition → rows | In memory only (`sql-on-fhir/view`'s `eval-view`) |
| Rows into SQLite / DuckDB | Missing |
| ViewDefinitions for the resources measures read | Missing (only spec examples exist) |
| Retrieve, value sets, FHIR properties in SQL | Missing (Retrieve raises untranslatable) |
| Whole libraries in SQL (defines, refs, functions, FHIRHelpers, parameters) | Missing |
| Per-patient comparison SQL vs. interpreter | Missing |
| MeasureReport from the interpreter | Done: `evaluate-measure`, a report group per Measure.group, the measurement period parameter by its declared name and type |
| MeasureReport from SQL | Missing (phase 6) |
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
- **Next:** the same Bundles and score keys feed the relational model work ("Next: BCS-E over a
  relational model", R1–R5) and phase 6, the per-patient SQL vs. interpreter comparison.
- **Found on the way, for the shared repos (not patched here):**
  - fsh fails on an integer literal inside a parameterized RuleSet
    (`regexp-replace*: contract violation … given: 1`; worked around in `rulesets.fsh`).
  - fsh writes `compose: {}` for a ValueSet with no rules, where SUSHI writes none.
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
