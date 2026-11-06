// Profiles for SQL Libraries generated from CQL

Profile: CqlSqlQueryLibrary
Parent: Library
Id: cql-sql-query-library
Title: "CQL SQLQuery Library"
Description: "A FHIR Library resource containing executable SQL translated from CQL logic, returning patient cohort populations over SQL-on-FHIR ViewDefinitions."
* type = #module
* content 1..*
* content.contentType 1..1
* content.contentType from http://hl7.org/fhir/ValueSet/mimetypes (required)
* relatedArtifact ^slicing.discriminator.type = #value
* relatedArtifact ^slicing.discriminator.path = "type"
* relatedArtifact ^slicing.rules = #open
* relatedArtifact contains dependsOn 0..*
* relatedArtifact[dependsOn].type = #depends-on
* relatedArtifact[dependsOn].resource 1..1

Profile: CqlSqlViewLibrary
Parent: Library
Id: cql-sql-view-library
Title: "CQL SQLView Library"
Description: "A FHIR Library resource representing a graph of SQL-on-FHIR SQLViews corresponding to CQL definitions."
* type = #module
* content 1..*
* content.contentType = #"application/sql"
