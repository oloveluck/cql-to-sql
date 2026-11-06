# Retargeting and translating a CQL query: how the process works

> **Highly experimental, not fully tested.** Everything below describes the code as it is in
> this repo today. It is a prototype: the translator covers a subset of CQL, has one end-to-end
> oracle (the demo measure, 12 patients) plus the HL7 expression suite, and no real measure has
> been through it. Where this page says "today" or "not yet", read it as a limit, not a plan.

A CQL query written for FHIR data is made to run as SQL in two steps that meet at a table shape:

- **Retargeting** moves the *data* from FHIR resources into relational tables, through SQL-on-FHIR
  ViewDefinitions. The tables are the target the SQL is written against.
- **Translating** turns the *logic* (the CQL, through its ELM) into one SQL query over those
  tables.

Then the query runs, its rows become MeasureReports, and those are compared with the interpreter's.

```
CQL text ──(cql: parse-cql, compile-library)──▶ ELM library
ELM library ──(library.rkt: translate-library)──▶ sql-with: a CTE per define + the population SELECT
sql-with ──(sql/print.rkt: sql->string, dialect)──▶ SQL text with :period_start / :period_end
SQL text + tables ──(db, SQLite)──▶ rows: patient_id, initial-population, denominator, numerator
rows ──(library.rkt: sql-result->measure-reports, cql/measure's measure-report)──▶ MeasureReports
```

## Retargeting: the tables the SQL runs over

The translator does not read ViewDefinitions. It assumes a fixed table shape, which the
ViewDefinitions must produce. That shape is the contract between the two halves.

**What the translator expects today** (the shape of `demo/views/`, which is what every test
runs over):

| Table | Columns | Built by |
|---|---|---|
| `patient` | `id`, plus one column per Patient property the CQL reads (`gender`, `birth_date`) | `demo/views/patient.json` |
| one table per retrieved resource type, named by the type in snake case (`observation`, `medication_dispense`) | `id`, `patient_id`, one column per property read (`status`, `effective`, …), and for a value-set retrieve `code_system` and `code` — **one row per coding** (`forEach: code.coding`) | `demo/views/observation.json` |
| `valueset_code` | `url`, `system`, `code`: every value set's expansion | `demo/run.rkt`'s `load-valueset!` from a ValueSet with an `expansion` |

How a FHIR property becomes a column (`translate.rkt`, `fhir-path->column-name`): a short fixed
table (`birthDate` → `birth_date`, `gender`, `status`, `effective`, `performed` →
`performed_datetime`, `occurrence` → `occurrence_datetime`, `id`), and otherwise the snake-cased
first step of the path (`subject.reference` → `subject`). A `.value` suffix (the ELM's primitive
unwrapping, `effective.value`) maps to the same column. Column types come from a similar fixed
table (`resource-col-type`: `birth_date` is a Date, the `*_datetime` and `effective` columns are
DateTimes, everything else a String). Anything not in those tables is a String column named after
the path, whether or not the view has it: the SQL fails at run time, not at translation.

Dates are ISO text, never SQL `date`/`timestamp`, because CQL compares at the precision written
(`1965` is not `1965-01-01`); comparisons of two lexemes decide by their common prefix and are
null when the prefixes agree but the precisions differ (`temporal-compare`).

**Building the tables.** `demo/run.rkt` evaluates each ViewDefinition in memory with
`sql-on-fhir`'s view engine (`view-rows`) and inserts the rows into SQLite, one `CREATE TABLE` per
view with the view's column names; `valueset_code` is filled from the ValueSet's expansion. Any
SQL-on-FHIR engine that materialises the same ViewDefinitions (Aidbox `$materialize`, Pathling)
produces the same tables; `demo/aidbox-load.json` does that for Aidbox, but the generated SQL has
only been run in SQLite.

**The relational model in `model/` is a second, wider target that the translator does not use
yet.** `model/spec.rkt` declares 86 ViewDefinitions for the 14 resource types HEDIS BCS-E reads
(normalised child tables, `patient_id` on every row, statuses and negations kept, extensions as
rows, dates as text) over **FHIR R6** data; `model/r4-to-r6.rkt` converts the R4 corpora losslessly
first, and `model/build.rkt` loads them into SQLite with indexes on the retrieve's access paths.
Its naming differs from the demo's: the resource key is `observation_id`, codings live in a child
table `observation_code_coding(system, code)`, and R6 status codes replace R4 ones (`finished` →
`completed`, with the R4 code kept in `status_r4`). Pointing `translate.rkt` at this shape (a key
column per type, a join to the coding table instead of `code_system`/`code` on the resource row,
R4 → R6 code mapping) is the next step; it is not done. See `model/README.md` and `PLAN.md`
(R1–R5).

**Dialects.** The translator asks the dialect (`sql/dialect.rkt`) for every engine-specific
operation (JSON construction and extraction, `substr`, casts, `julianday`, the age calculation,
raising a runtime error); the printer (`sql/print.rkt`) differs per dialect only in parameter
syntax (`:name` for SQLite, `$name` for DuckDB). Two dialect tables exist, `sqlite` and `duckdb`.
Only SQLite is executed by any test; DuckDB output has not been run. There is no PostgreSQL
dialect; `demo/BreastScreeningDemo.postgres.sql` was written by hand.

## Translating: CQL → ELM → SQL

### 1. CQL to ELM (the `cql` package)

`cql->sql` (`library.rkt`) calls `parse-cql` and `compile-library` from the `cql` package and
fails with their error if either fails. The translator therefore sees typed ELM with the
compiler's choices already made: overloaded operators resolved, FHIR properties unwrapped to
their `.value`, `AgeInYearsAt` as a precision operation, timing phrases lowered to the ELM
timing/between nodes, FHIRHelpers conversions inserted as function references.

### 2. A term per ELM node (`translate.rkt`)

`translate : ELM TEnv -> Term` is a `match` with one clause per ELM variant. A **Term** is a SQL
expression plus the CQL type of its value. The type decides the **encoding** (`types.rkt`):

| CQL type | SQL encoding |
|---|---|
| Boolean, Integer, Long | INTEGER (Boolean as 0/1; an Integer result outside 32 bits becomes NULL, as CQL's does) |
| Decimal | REAL (so 28-digit decimals are a known loss; comparisons round to 8 places) |
| String, Date, DateTime, Time | TEXT (temporal values as their ISO lexeme; precision = the lexeme's length) |
| List, Tuple, Interval, Quantity, Code, Concept, Ratio | JSON text: arrays; objects; `{"low","high","lowClosed","highClosed"}`; `{"value","unit"}` |
| a resource row | a column reference to the row's `id`, typed `(Resource "Observation")` |
| a relation | a define that is a set of patients' rows (see 3) |

CQL `null` is SQL NULL everywhere, so three-valued `and`/`or`/`not` are SQL's own.

What the dispatch covers:

- **Literals** of the scalar types; Date/DateTime/Time literals folded to one lexeme (a literal
  built from computed components is untranslatable); `Quantity` literals as JSON; lists, tuples
  and intervals built with the dialect's JSON constructors.
- **`if` / `case`** as `CASE`, the branches' types unified.
- **Properties** of a resource row (a column, by the table above), of a tuple (JSON extraction),
  of an interval (`low`/`high`/`lowClosed`/`highClosed`), of a quantity (`value`/`unit`).
- **Queries over lists** (`from … where … return … sort by`, with `let`, `with`/`without … such
  that` as `EXISTS`/`NOT EXISTS`): each source is a `json_each` table function, the result is
  re-aggregated with `json_group_array` in the sorted order; a single-value source is a scalar
  subquery. The `aggregate` clause and a query mixing list and single-value sources are
  untranslatable.
- **Queries over a retrieve** are the relational case, described in 3.
- **`as`** re-types the term; **`is`** is decided from the static type (an `Any` operand is
  untranslatable, never guessed).
- **`year from x`** and the other components read the lexeme's digits (NULL below the written
  precision); `date from` / `time from` are substrings.
- **Timing**: `in`/`during` (a point in an interval via `julianday … BETWEEN`; an interval in an
  interval via its bounds), `before`, `after`, and `between`. A timing phrase **with a precision**
  (`before day of`) and **`overlaps`** are untranslatable today.
- **`AgeInYearsAt` / `CalculateAge[At]`** through the dialect's `age-in-years-at` (year difference
  minus one when the month-day has not been reached).
- **Parameters**: `"Measurement Period"` (either capitalisation) becomes a DateTime interval
  whose bounds are the named SQL parameters `:period_start` and `:period_end`, closed on both
  sides; any other parameter becomes a parameter named after it (`"My Param"` → `:my_param`) of
  unknown type. No code binds the parameters; the caller substitutes values into the SQL text.
- **References** to another define read that define's CTE (see 3); `Patient` is the row `p` of
  the `patient` table.
- **Functions**: only `FHIRHelpers.ToString/ToDateTime/ToDate/ToTime/ToBoolean/ToInteger/
  ToDecimal/ToQuantity/ToConcept/ToCode` (and the same names unqualified), each a re-typing of
  its argument with no SQL, because the column already holds the primitive value. Any other
  function call, including a library's own `define function`, is untranslatable.
- **Operators** are a registry keyed by the ELM operator name (`def-op!`, like the interpreter's),
  65 today: arithmetic (`Add` … `Power`, `Round`, `Successor`, `Predecessor`, with quantity
  arithmetic in one unit or across the fixed unit table), comparison (`Less` … `Equal`,
  `NotEqual`, `Equivalent`, structural over tuples and intervals, quantities by a unit table, a
  unit pair outside the table a runtime error rather than a guess), logic (`And`, `Or`, `Not`,
  `Implies`, `Xor`), nullology (`IsNull`, `IsTrue`, `IsFalse`, `Coalesce`), strings
  (`Concatenate`, `Upper`, `Lower`, `StartsWith`, `EndsWith`, `Substring`, `PositionOf`,
  `Combine`, `Length`, `Indexer`), conversions (`ToString`, `ToInteger`, `ToDecimal`,
  `ToBoolean`), lists (`Exists`, `Count`, `Sum`, `Min`, `Max`, `Avg`, `In`, `Contains`, `First`,
  `Last`, `SingletonFrom`, `Distinct`, `Union`) and intervals (`Start`, `End`, `In`).

Everything else raises `exn:fail:untranslatable` carrying the ELM node and a message naming the
construct. That is the rule the whole translator follows: **never SQL that computes something
else.** `tests/tck.rkt` counts those messages, so the most common gaps are known (`racket
tests/tck.rkt -v`).

### 3. A Library as one query (`library.rkt`)

`translate-library` takes the compiled ELM library and an optional FHIR Measure (as JSON) and
returns a `sql-with`: a list of CTEs and a final SELECT.

1. **Names.** The library's `valueset` declarations give a map from name to canonical url; its
   `parameter` declarations are kept by name. The implicit `Patient` define is dropped (it is the
   `patient` table).
2. **Order.** The defines are sorted topologically by the `ExpressionRef`s each one's expression
   contains, so every CTE comes after the ones it reads.
3. **One CTE per define**, named by the define in snake case (`"Mammograms During Period"` →
   `mammograms_during_period`) and given a short alias. The CTE's shape depends on the define's
   expression:

   | The define is… | The CTE | Its kind |
   |---|---|---|
   | a query whose first source is a **retrieve** (`[Observation: "VS"] O where …`) | `SELECT DISTINCT o.patient_id, o.id FROM observation AS o [JOIN valueset_code AS vs ON vs.url = '<url>' AND vs.system = o.code_system AND vs.code = o.code] WHERE <where>` | relation: the patients' matching rows |
   | a precision operation (`AgeInYearsAt(…)`) or a property of `Patient` | `SELECT p.id AS patient_id, <expr> AS age|v FROM patient AS p` | scalar: one value per patient |
   | anything else | `SELECT p.id AS patient_id, coalesce(<expr>, 0) AS v FROM patient AS p JOIN <each referenced scalar or boolean CTE> ON its.patient_id = p.id` | boolean: one 0/1 per patient (a Boolean that is CQL null becomes 0) |

   Inside a boolean define, a reference to a scalar or boolean define is its CTE's column through
   the join; a reference to a relation define is usable only through `exists`, which becomes
   `EXISTS (SELECT 1 FROM <cte> AS m WHERE m.patient_id = p.id)`. The value-set join is keyed by
   the retrieve's `ValueSetRef` resolved to its url (or an inline url string); the retrieve's
   `where` is translated with the alias bound to the row.

   This is population-level SQL: every CTE is a relation over all patients keyed by `patient_id`,
   never a query per patient (`PLAN.md`, R5).

4. **The population query.** With a Measure, the define behind each population is read from
   `group[].population[].criteria.expression` by its code (`initial-population`, `denominator`,
   `numerator`, `denominator-exclusion`; the first population of each code across the groups).
   Without one, the defines named `"Initial Population"`, `"Denominator"` and `"Numerator"` are
   used. The query inner-joins the CTEs on `patient_id` and emits:

   ```sql
   SELECT ip.patient_id AS patient_id,
          ip.v AS "initial-population",
          d.v AS "denominator",
          (d.v AND n.v) AS "numerator"
   FROM initial_population AS ip
   JOIN denominator AS d ON d.patient_id = ip.patient_id
   JOIN numerator   AS n ON n.patient_id = ip.patient_id
   ORDER BY ip.patient_id ASC
   ```

   Only these four columns are produced today. A `denominator-exclusion` define is joined but not
   emitted, and the denominator is the define's own value, not `ip AND d`; the demo's defines
   nest properly (its `"Denominator"` is `"Initial Population"`), so the output agrees with the
   interpreter there. Stratifiers, several groups, and non-proportion scoring are not handled.

5. **Text.** `sql->string` prints the AST for the dialect's name. Every compound expression is
   parenthesised, identifiers are quoted only when they must be, and parameters print as
   `:period_start` (SQLite) or `$period_start` (DuckDB).

### 4. Running, decoding, reporting

- **A whole Library** runs through `db` against the tables above (`demo/run.rkt`, and the test in
  `library.rkt`). The caller binds the parameters (the demo replaces `:name` with literals).
- **One expression** runs through `run.rkt`: `run-expression` translates it in an empty
  environment, executes `SELECT <sql> AS v` in an in-memory SQLite, and `decode.rkt` turns the
  result back into a CQL value by the term's type (NULL → `null`, 0/1 → Boolean, REAL → Decimal
  rounded to 8 places, ISO text → Date/DateTime/Time, JSON → lists, tuples, intervals,
  quantities, codes). A SQL runtime error, including the deliberate ones the translator raises
  (`SingletonFrom` over two elements, quantities needing UCUM), is `exn:fail:sql-run`.
- **MeasureReports** come from `sql-result->measure-reports`: each row's population columns
  (1 or true → 1, else 0) become an `individual` MeasureReport per patient and their sums a
  `summary` one, through `cql/measure`'s `measure-report`, the same builder the interpreter uses.
  So a difference between the two sides is a difference in the populations, never in the report
  assembly.

## The oracles

| Oracle | What it checks | Where |
|---|---|---|
| The HL7 CQL test suite (vendored in `cql`) through SQL | each `<expression>` compiled, translated, run in SQLite and decoded; the `<output>` evaluated by the interpreter; compared with the interpreter's own `test-equal?` | `tests/tck.rkt`, floor in `tests/tck-test.rkt`: 902 pass, 4 named failures (Decimal precision in SQLite's REAL), 875 untranslatable, 42 skipped (tests the compiler rejects, library tests) |
| The demo measure, generated SQL | `cql->sql` on `demo/BreastScreeningDemo.cql` with `demo/measure.json`, run over the 12 demo patients flattened by `demo/views/`; every individual and the summary MeasureReport equal to `evaluate-measure`'s | `library.rkt`'s test submodule: 13/13 |
| The demo measure, hand-written SQL | the same comparison with `demo/BreastScreeningDemo.sql` | `demo/run.rkt`: 13/13 |

A pass means the SQL gave the same value as the interpreter, which is itself checked against the
HL7 suite (1820/1823) and the eCQM corpus (71/76) in the `cql` repo. There is no oracle yet for a
real measure in SQL: BCS-E runs only in the interpreter (`demo/bcse/`, `tests/bcse-scenarios-test.rkt`).

## Known limits

Each of these is a limit of the code today, not a design intent:

- **Coverage.** The most common untranslatable constructs in the suite are timing phrases with a
  precision and `overlaps`, `between` over non-intervals, `+`/`-` on operands of unknown type,
  `Expand`, `Intersect`, `Except`, `Collapse`, the `aggregate` clause, `MinValue`/`MaxValue`,
  `ToDateTime`, `AnyTrue`/`AllTrue`, `Today`, and any user-defined function.
- **A retrieve filtered by a Code rather than a value set** (`[Observation: "SomeCode"]`, an ELM
  `CodeRef`) is translated **without** its code filter: only `ValueSetRef` and an inline url
  produce the `valueset_code` join. This is the one place the translator is lenient instead of
  refusing, and it is wrong for such retrieves.
- **A retrieve not used as a query's first source** (bare `[Observation]` inside an expression)
  translates to the table name as a resource row; most uses of it then fail.
- **Column mapping is a fixed table**, not read from the ViewDefinition or the ModelInfo: a
  property outside it becomes a column named after the path, typed String, and the engine
  reports a missing column at run time. Choice types other than `effective`/`performed`/
  `occurrence` as DateTime, Periods, references and nested elements are not mapped.
- **Parameters** other than the measurement period are untyped, and nothing binds them.
- **Decimals** are doubles; **temporal comparisons** assume equal offsets.
- **The population query** emits four columns, inner-joins (a patient missing from any CTE
  disappears), takes the first group's populations, and applies no exclusion arithmetic.
- **Only SQLite has been executed.** DuckDB prints but is unrun; PostgreSQL does not exist as a
  dialect.
- **Performance** has not been measured; the SQL is unoptimised (no indexes are assumed beyond
  what `model/build.rkt` creates, and the translator does not yet run over those tables).
- **The IG** (`ig/`) defines `Library/$cql-to-sql`, the CqlSqlQuery/CqlSqlView Library profiles
  and a column-binding extension; none is implemented in code, and `cql->sql` returns SQL text,
  not a Library resource.
