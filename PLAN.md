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
3. **Retrieve and properties.** `[Condition: "VS"]` → select on the view table joined to the
   value set table, filtered to the current patient; property paths → view columns; FHIRHelpers
   calls → direct SQL. Check with small hand-written libraries against the interpreter.
4. **Whole libraries.** Defines as CTEs, references and functions inlined, Measurement Period
   as a query parameter; one query, one row per patient, a column per define.
5. **Measure-level comparison.** For each of the 76 eCQM patients compare the population
   defines between SQL and the interpreter; floor that only rises, named known mismatches.
6. **Wrap-up.** DuckDB dialect, output as SQL-on-FHIR SQLQuery/SQLView Library, `ig/` with
   `Library/$cql-to-sql`.

## Open questions

- What counts as "the same": SQL vs. interpreter per define, or vs. the expected MeasureReport
  (where the interpreter agrees on 71 of 76)? Not decided yet.
- Which CQL matters most: the eCQM corpus, or EBMEDS rules?
- Division of phases between team members and Owen.
