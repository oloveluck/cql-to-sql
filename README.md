# cql-to-sql

Translate CQL Libraries into SQL over relational tables built by
[SQL on FHIR](https://sql-on-fhir.org) ViewDefinitions.

A CQL Library (or a Measure's Library) plus ViewDefinitions for the FHIR resource types it
retrieves becomes a SQL-on-FHIR **SQLQuery** or **SQLView** Library. The query returns one row per
patient, with a column per selected define (a Measure's populations). SQLite is the first
dialect and runs in-process for testing; DuckDB is the second.

Status: early. The translator is being built against two oracles: the HL7 CQL test suite
(each expression translated, run in SQLite, compared with the expected result) and the eCQM
corpus (per-patient populations equal to the interpreter's).

The package also defines a FHIR Implementation Guide (in `ig/`, authored in FSH): the
`Library/$cql-to-sql` operation, the CqlSqlQuery/CqlSqlView profiles, and the extensions
that bind view columns to CQL properties.

Builds on the Racket packages [`cql`](https://github.com/oloveluck/cql) (CQL → ELM, interpreter)
and [`sql-on-fhir`](https://github.com/oloveluck/sql-on-fhir) (ViewDefinitions).

```sh
raco pkg install --link --auto cql-to-sql
raco test cql-to-sql
```

MIT licensed.
