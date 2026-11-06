#lang info

;; cql-to-sql — CQL Libraries as SQL over SQL-on-FHIR ViewDefinitions.
;;
;; A CQL Library (its ELM, from the cql package) plus the ViewDefinitions of the resource types it
;; retrieves becomes a SQL-on-FHIR SQLQuery or SQLView Library: one row per patient, a column per
;; define. SQLite first (run in-process for the oracles), DuckDB as a second dialect.

(define collection "cql-to-sql")
(define version "0.1")
(define pkg-desc "CQL to SQL: translate CQL Libraries (via ELM) into SQL-on-FHIR SQLQuery/SQLView Libraries over ViewDefinition tables; SQLite and DuckDB dialects")
(define pkg-authors '(oloveluck))
(define license 'MIT)
(define deps '("base" "fhir" "fhirpath" "cql" "sql-on-fhir" "db-lib"))
;; fsh: tests/bcse-scenarios-test.rkt compiles and checks the BCS-E scenarios (fsh/check)
(define build-deps '("rackunit-lib" "fsh"))
(define test-omit-paths '("scribblings"))
