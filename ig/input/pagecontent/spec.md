# Specification & Architecture

> **Highly experimental, not fully tested.** This page states what the translator in
> [oloveluck/cql-to-sql](https://github.com/oloveluck/cql-to-sql) does today, not a finished
> specification. The authoritative description is the repository's `docs/translation.md`.

### Compilation Scheme

The input is ELM, produced from the CQL by the `cql` package's compiler, so overloads, implicit
conversions and FHIRHelpers calls are already resolved. The translator is a structural recursion
over the ELM: every node becomes a SQL syntax-tree fragment with a CQL type, and the type fixes
the SQL encoding of the value.

| CQL type | SQL encoding |
|---|---|
| Boolean, Integer, Long | INTEGER (Boolean 0/1; an Integer outside 32 bits is NULL) |
| Decimal | REAL (a known precision loss) |
| String, Date, DateTime, Time | TEXT; temporal values as their ISO lexeme at the written precision |
| List, Tuple, Interval, Quantity, Code, Concept | JSON text |

CQL `null` is SQL NULL, so three-valued logic is SQL's own. A construct without a translation
raises an "untranslatable" error; the translator never emits SQL that computes something else.

#### 1. Language Mapping

| CQL / ELM construct | SQL |
|---|---|
| `define "Name": <expr>` | a CTE `name AS (SELECT p.id AS patient_id, coalesce(<expr>, 0) AS v FROM patient AS p JOIN <referenced defines> …)` |
| `define "Name": [Observation: "VS"] O where …` | a CTE `SELECT DISTINCT o.patient_id, o.id FROM observation AS o JOIN valueset_code AS vs ON vs.url = '<url>' AND vs.system = o.code_system AND vs.code = o.code WHERE …` |
| `define "Name": AgeInYearsAt(…)` or `Patient.<property>` | a CTE `SELECT p.id AS patient_id, <expr> AS age FROM patient AS p` |
| `"Other Define"` (a reference) | the referenced CTE's column, joined on `patient_id` |
| `exists "Relation Define"` | `EXISTS (SELECT 1 FROM relation_define AS m WHERE m.patient_id = p.id)` |
| `Patient.gender`, `O.status`, `O.effective` | a column of the row: a fixed property-to-column table (`birthDate` → `birth_date`, `effective`, `performed` → `performed_datetime`, …), else the snake-cased first path step |
| `AgeInYearsAt(d)` | the dialect's `age-in-years-at`: year difference, minus one before the birthday |
| `X during I`, `X in I` (a point in an interval) | `julianday(X) BETWEEN julianday(low) AND julianday(high)` |
| `X in { 'a', 'b' }` | a `CASE` over `X IS 'a'`, `X IS 'b'`, … |
| `"Measurement Period"` | an interval whose bounds are the named parameters `:period_start` and `:period_end` (closed); nothing binds them |
| `FHIRHelpers.ToX(v)` | the argument, re-typed; no SQL |
| a query over a list (`from … where … return … sort by`, `with`/`without`) | `json_each` sources, `EXISTS`/`NOT EXISTS`, re-aggregated with `json_group_array` |
| timing with a precision (`before day of`), `overlaps`, `aggregate`, user functions, `Today`, `ToDateTime`, interval set operations | untranslatable today |

#### 2. Dialects

The syntax tree asks a dialect table for every engine-specific operation and is printed per
dialect:

- **SQLite**: the only engine any test executes; in-process for the oracles.
- **DuckDB**: a dialect table exists and prints (`$name` parameters), but its output has not been
  run.
- **PostgreSQL / Aidbox**: no dialect exists. The repository's PostgreSQL demo SQL is hand-written.

#### 3. The Population Query

With a Measure, the define behind each population is read from
`group.population.criteria.expression` by its code; without one, the defines named
`"Initial Population"`, `"Denominator"` and `"Numerator"` are used. The CTEs are inner-joined on
`patient_id` and the query returns one row per patient:

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

These four columns are all it produces today: a `denominator-exclusion` define is joined but not
emitted, one group is read, and no stratifier or non-proportion scoring is handled. The rows
become `individual` and `summary` MeasureReports through the interpreter's report builder.
