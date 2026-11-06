# Plan

Mission: run CQL with the interpreter, translate the same CQL to SQL over SQL-on-FHIR
ViewDefinition tables, and check that the results are the same.

Hackathon context: we work in this repo (oloveluck/cql-to-sql) together with Owen. Pull often,
keep commits small, follow the conventions in `../fhir/CLAUDE.md` and `../cql/CLAUDE.md` (HTDP
style, `contract-out`, `module+ test` in every module, floors that only rise).

A diagram of the target architecture will be added later; revise this plan to match it.

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
| FHIR → ViewDefinition → rows | In memory only (`sql-on-fhir/view`'s `eval-view`) |
| Rows into SQLite / DuckDB | Missing |
| ViewDefinitions for the resources measures read | Missing (only spec examples exist) |
| Retrieve, value sets, FHIR properties in SQL | Missing (Retrieve raises untranslatable) |
| Whole libraries in SQL (defines, refs, functions, FHIRHelpers, parameters) | Missing |
| Per-patient comparison SQL vs. interpreter | Missing |
| Running the SQL in Aidbox (cloud, PostgreSQL) | Missing: REST connector and PostgreSQL dialect |

Most common untranslatable constructs in the SQL TCK: `elm-timing` (464), `elm-between` (54),
`+`/`-` on Any (65), Expand, Intersect, Except, aggregate clause, `elm-minmax`, ToDateTime,
Collapse, AnyTrue/AllTrue, Today.

## Phases

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
6. **Measure-level comparison.** For each of the 76 eCQM patients compare the population
   defines between SQL and the interpreter, in SQLite and in Aidbox; floor that only rises,
   named known mismatches.
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
- **Pending:** evaluating BCSE_Details over the scenarios and comparing with the score keys needs
  the cql compiler to translate NCQA's libraries (13/43 compile today; Niko). Then the same Bundles
  and score keys feed phase 6, the per-patient SQL vs. interpreter comparison.
- **Found on the way, for the shared repos (not patched here):**
  - fsh fails on an integer literal inside a parameterized RuleSet
    (`regexp-replace*: contract violation … given: 1`; worked around in `rulesets.fsh`).
  - fsh writes `compose: {}` for a ValueSet with no rules, where SUSHI writes none.
  - `fhir/sd/sd-index` finds conformance resources only by `StructureDefinition-*.json`-style file
    names, so a package with other names (NCQA's) is invisible to fsh and the validator, and
    validation then passes by failing open.

## Open questions

- What counts as "the same": SQL vs. interpreter per define, or vs. the expected MeasureReport
  (where the interpreter agrees on 71 of 76)? Not decided yet.
- Which CQL matters most: the eCQM corpus, or EBMEDS rules?
- Division of phases between team members and Owen.
- Aidbox: is the cloud instance shared? Tests create ViewDefinitions, `sof.*` tables and load
  76 test patients, so use a dedicated instance or a prefix (e.g. `cql2sql_`) with cleanup.
- Aidbox: which Client and access policy may call `$sql` and `$materialize`?
