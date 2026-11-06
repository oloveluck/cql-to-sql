# CQL to SQL on FHIR Implementation Guide

### Overview

**cql-to-sql** translates Clinical Quality Language (CQL) Libraries and eCQM/HEDIS Measures into executable SQL queries over relational tables created by [SQL on FHIR](https://sql-on-fhir.org) `ViewDefinition`s.

```
CQL Measure ──(cql->sql)──▶ SQL Query ──(execute in DB)──▶ Population Rows ──(sql-result->measure-reports)──▶ MeasureReports
```

### Core Architecture

1. **Relational Model over FHIR**:
   - Resources read by CQL are flattened into flat tables via SQL-on-FHIR `ViewDefinition`s.
   - Repeating elements (codings, lines, diagnoses) are represented in normalized child tables.
   - Every row traces back to its source resource key and `patient_id`.

2. **Population-Level Query Compilation**:
   - CQL `define` statements in `context Patient` compile to SQL Common Table Expressions (CTEs) carrying `patient_id`.
   - Query execution evaluates all patients in the population in a single query rather than iterating one patient at a time.
   - The query produces one row per patient with a column for each population criteria (`initial-population`, `denominator`, `numerator`, `denominator-exclusion`).

3. **Oracles and Verification**:
   - Tested against the official HL7 CQL test suite (900+ passing tests).
   - Validated by comparing SQL results row-by-row and `MeasureReport`-by-`MeasureReport` against the Racket `cql` interpreter.

### Profiles & Operations

- [CQL SQLQuery Library Profile](StructureDefinition-cql-sql-query-library.html): A FHIR Library representing translated SQL queries with linked `ViewDefinition` dependencies.
- [CQL SQLView Library Profile](StructureDefinition-cql-sql-view-library.html): A FHIR Library representing a graph of SQL-on-FHIR views.
- [Library/$cql-to-sql Operation](OperationDefinition-Library-cql-to-sql.html): FHIR operation definition for translating CQL to SQL.
- [Specification & Architecture](spec.html): Detailed compilation and translation rules.
