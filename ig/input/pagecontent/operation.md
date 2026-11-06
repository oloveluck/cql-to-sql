# Operation: Library/$cql-to-sql

> **Not implemented.** This OperationDefinition describes the intended interface. No server in
> the [cql-to-sql](https://github.com/oloveluck/cql-to-sql) repository serves it; today the
> translation is a Racket procedure, `cql->sql` in `library.rkt`, which returns SQL text rather
> than a Library resource. The whole project is highly experimental and not fully tested.

### Synopsis

`POST [base]/Library/$cql-to-sql`
`POST [base]/Measure/$cql-to-sql`
`POST [base]/Library/[id]/$cql-to-sql`
`POST [base]/Measure/[id]/$cql-to-sql`

### Description

Translates a CQL Library, or the Library a Measure names, into one SQL query over SQL-on-FHIR
ViewDefinition tables, returned as a `CqlSqlQueryLibrary` (one query: a CTE per define and a
population `SELECT`) or a `CqlSqlViewLibrary` (a graph of views).

### Input Parameters

- `library` (0..1, `Library`): the CQL Library to translate (`content` of type `text/cql`).
- `measure` (0..1, `Measure`): the Measure whose `group.population.criteria` name the population
  defines; without it the defines `"Initial Population"`, `"Denominator"` and `"Numerator"` are
  used.
- `dialect` (0..1, `code`): the SQL dialect. The code today has `sqlite` (default, the only one
  executed) and `duckdb` (prints, unrun). `postgresql` is intended but does not exist.
- `periodStart`, `periodEnd` (0..1, `date`): the measurement period. The generated SQL carries
  the period as the named parameters `:period_start` and `:period_end`; these inputs would bind
  them.

### Output Parameters

- `return` (1..1, `Library` conforming to `CqlSqlQueryLibrary`): the SQL in `content`
  (`application/sql`) and the required `ViewDefinition`s as `relatedArtifact`s of type
  `depends-on`.
