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
- **Next:** the same Bundles and score keys feed phase 6, the per-patient SQL vs. interpreter
  comparison.
- **Found on the way, for the shared repos (not patched here):**
  - fsh fails on an integer literal inside a parameterized RuleSet
    (`regexp-replace*: contract violation … given: 1`; worked around in `rulesets.fsh`).
  - fsh writes `compose: {}` for a ValueSet with no rules, where SUSHI writes none.
  - `fhir/sd/sd-index` finds conformance resources only by `StructureDefinition-*.json`-style file
    names, so a package with other names (NCQA's) is invisible to fsh and the validator, and
    validation then passes by failing open.

## Open questions

- What counts as "the same": proposed, the SQL MeasureReport equals the interpreter's (phase 6),
  per patient and in summary. Comparing with the expected MeasureReports in the test data
  (where the interpreter agrees on 71 of 76) is a separate check of the interpreter.
- Which CQL matters most: BCS-E is the target now; the eCQM corpus stays as a second test set.
- Where do the NCQA value sets come from, and may they be stored in Aidbox / the repo?
- Licensing of the uploaded NCQA files in this public repo.
- Division of phases between team members and Owen.
- Aidbox: is the cloud instance shared? Tests create ViewDefinitions, `sof.*` tables and load
  76 test patients, so use a dedicated instance or a prefix (e.g. `cql2sql_`) with cleanup.
- Aidbox: which Client and access policy may call `$sql` and `$materialize`?
