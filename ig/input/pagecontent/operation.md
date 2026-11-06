# Operation: Library/$cql-to-sql

### Synopsis

`POST [base]/Library/$cql-to-sql`
`POST [base]/Measure/$cql-to-sql`
`POST [base]/Library/[id]/$cql-to-sql`
`POST [base]/Measure/[id]/$cql-to-sql`

### Description

Translates a CQL Library or Measure into an executable SQL query formatted as a `CqlSqlQueryLibrary` or `CqlSqlViewLibrary`.

### Input Parameters

- `library` (0..1, `Library`): The CQL Library resource to translate.
- `measure` (0..1, `Measure`): The Measure referencing the CQL Library.
- `dialect` (0..1, `code`): Target SQL dialect (`sqlite`, `duckdb`, `postgresql`). Default: `sqlite`.
- `periodStart` (0..1, `date`): Measurement period start.
- `periodEnd` (0..1, `date`): Measurement period end.

### Output Parameters

- `return` (1..1, `Library` conforming to `CqlSqlQueryLibrary`): The resulting Library resource containing the translated SQL in `.content` and referencing required `ViewDefinition`s in `.relatedArtifact`.
