// OperationDefinition: Library/$cql-to-sql

Instance: LibraryCqlToSql
InstanceOf: OperationDefinition
Usage: #definition
Title: "Translate CQL to SQL-on-FHIR Query"
Description: "Translates a CQL Library or Measure into an executable SQL-on-FHIR SQLQuery Library over relational ViewDefinitions."
* url = "https://oloveluck.github.io/cql-to-sql/OperationDefinition/Library-cql-to-sql"
* name = "CqlToSql"
* status = #draft
* kind = #operation
* affectsState = false
* code = #cql-to-sql
* resource[0] = #Library
* resource[+] = #Measure
* system = false
* type = true
* instance = true

// Input parameters
* parameter[0].name = #library
* parameter[=].use = #in
* parameter[=].min = 0
* parameter[=].max = "1"
* parameter[=].documentation = "The CQL Library resource to translate."
* parameter[=].type = #Library

* parameter[+].name = #measure
* parameter[=].use = #in
* parameter[=].min = 0
* parameter[=].max = "1"
* parameter[=].documentation = "The FHIR Measure referencing the CQL Library."
* parameter[=].type = #Measure

* parameter[+].name = #dialect
* parameter[=].use = #in
* parameter[=].min = 0
* parameter[=].max = "1"
* parameter[=].documentation = "The target SQL dialect (sqlite, duckdb, postgresql)."
* parameter[=].type = #code

* parameter[+].name = #periodStart
* parameter[=].use = #in
* parameter[=].min = 0
* parameter[=].max = "1"
* parameter[=].documentation = "The start date of the measurement period."
* parameter[=].type = #date

* parameter[+].name = #periodEnd
* parameter[=].use = #in
* parameter[=].min = 0
* parameter[=].max = "1"
* parameter[=].documentation = "The end date of the measurement period."
* parameter[=].type = #date

// Output parameter
* parameter[+].name = #return
* parameter[=].use = #out
* parameter[=].min = 1
* parameter[=].max = "1"
* parameter[=].documentation = "The generated CqlSqlQueryLibrary containing SQL and ViewDefinition dependencies."
* parameter[=].type = #Library
* parameter[=].targetProfile = "https://oloveluck.github.io/cql-to-sql/StructureDefinition/cql-sql-query-library"
