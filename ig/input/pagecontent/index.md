# CQL to SQL on FHIR Implementation Guide

> **Highly experimental, not fully tested.** This guide describes a research prototype
> ([oloveluck/cql-to-sql](https://github.com/oloveluck/cql-to-sql)). The operation and profiles
> here are *definitions*: no server implements `$cql-to-sql` yet, the translator covers a subset
> of CQL, and it has been checked end to end only on one small demo measure and the HL7 CQL
> expression suite. Nothing here should be used to report a quality measure.

### Overview

**cql-to-sql** translates a Clinical Quality Language (CQL) Library, with the FHIR Measure that
names its populations, into one SQL query over relational tables created by
[SQL on FHIR](https://sql-on-fhir.org) `ViewDefinition`s, and checks the query against the CQL
interpreter.

```
FHIR resources ──ViewDefinitions──▶ tables        CQL ──cql──▶ ELM ──translate──▶ SQL
                                       └───── run the SQL (SQLite) ◀──────────┘
                                                    │
                                   one row per patient, a column per population
                                                    │
                                              MeasureReports, compared with the interpreter's
```

### How it works

1. **Retargeting the data.** Resources are flattened by `ViewDefinition`s into one table per
   resource type, one row per coding where a code is read, every row carrying `patient_id`, plus
   a `valueset_code(url, system, code)` table of the value set expansions. The translator writes
   SQL against this fixed shape; it does not read the `ViewDefinition`s.
2. **Translating the logic.** The CQL is compiled to ELM by the `cql` package. The translator is a
   structural recursion over ELM that builds a SQL syntax tree, one fragment per node, each with
   its CQL type (which decides the value's encoding: a native scalar, or JSON text for lists,
   tuples, intervals, quantities and codes). A whole Library becomes one `WITH` query: a CTE per
   `define` in dependency order, keyed by `patient_id`, and a final `SELECT` with a column per
   Measure population. A construct with no translation is refused, never approximated.
3. **Checking.** The rows become MeasureReports through the interpreter's own report builder, and
   the reports must equal the interpreter's.

The exact rules are on the [Specification](spec.html) page and, in full, in the repository's
`docs/translation.md`.

### What is verified

- The HL7 CQL expression suite, each expression translated, run in SQLite and compared with the
  expected value: 902 pass at the last recorded run, 4 known failures (SQLite's `REAL` is not a
  CQL Decimal), 875 untranslatable, 42 skipped.
- One demo measure (breast cancer screening, shaped like HEDIS BCS-E's core) over 12 patients:
  13 of 13 MeasureReports identical to the interpreter's.

No real measure has been translated; HEDIS BCS-E runs in the interpreter only. SQLite is the only
engine the generated SQL has been run in.

### Profiles & Operations (definitions only)

- [CQL SQLQuery Library Profile](StructureDefinition-cql-sql-query-library.html): a Library
  carrying translated SQL in `content`, with the `ViewDefinition`s it depends on as
  `relatedArtifact`s.
- [CQL SQLView Library Profile](StructureDefinition-cql-sql-view-library.html): a Library
  representing a graph of SQL-on-FHIR views, one per CQL define.
- [Library/$cql-to-sql Operation](OperationDefinition-LibraryCqlToSql.html): the operation that
  would translate a Library or Measure. Not implemented yet.
- [Specification & Architecture](spec.html): the compilation scheme.
