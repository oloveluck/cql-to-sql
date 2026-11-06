# Specification & Architecture

### Compilation Scheme

The compiler takes CQL/ELM expressions and translates each expression into an abstract syntax tree (AST) node representing the corresponding SQL operation.

#### 1. Language Mapping

| CQL / ELM Construct | SQL Representation |
|---|---|
| `define "Name"` | A Common Table Expression (CTE) `name AS (SELECT ...)` |
| `[Observation: "VS"]` | `SELECT ... FROM observation o JOIN valueset_code vs ON ...` |
| `Patient.gender` | Column reference `p.gender` on table `patient` |
| `exists X` | `EXISTS (SELECT 1 FROM x WHERE x.patient_id = p.id)` |
| `AgeInYearsAt(asOfDate)` | Year difference minus month/day adjustment (`age-in-years-at` dialect operation) |
| `X during Interval[A, B]` | `julianday(X) BETWEEN julianday(A) AND julianday(B)` |
| `X in { 'a', 'b', 'c' }` | `X IN ('a', 'b', 'c')` |
| `Measurement Period` | Named SQL query parameters (`:period_start`, `:period_end`) |

#### 2. Multi-Engine Dialects

The SQL AST is printed according to target dialect operations:

- **SQLite**: Local in-memory testing and embedded execution.
- **DuckDB**: Fast columnar engine for analytic cohorts.
- **PostgreSQL / Aidbox**: Cloud execution in Aidbox's `sof` schema.

#### 3. Proportion Scoring Rules

The final cohort query applies proportion measure scoring rules:

```sql
SELECT ip.patient_id AS patient_id,
       ip.v AS "initial-population",
       (ip.v AND d.v) AS "denominator",
       (ip.v AND d.v AND NOT e.v) AS "denominator-exclusion",
       (ip.v AND d.v AND NOT e.v AND n.v) AS "numerator"
FROM initial_population ip
JOIN denominator d ON d.patient_id = ip.patient_id
...
```
