// Example: BreastScreeningDemo translated to CqlSqlQueryLibrary

Instance: BreastScreeningDemoSqlQuery
InstanceOf: CqlSqlQueryLibrary
Title: "Breast Cancer Screening Demo SQL Library"
Description: "Generated SQL-on-FHIR SQLQuery Library for the BreastScreeningDemo measure."
* status = #draft
* name = "BreastScreeningDemoSqlQuery"
* url = "https://oloveluck.github.io/cql-to-sql/Library/BreastScreeningDemoSqlQuery"
* version = "1.0.0"
* type = #module
* relatedArtifact[dependsOn][0].type = #depends-on
* relatedArtifact[dependsOn][=].resource = "http://example.org/fhir/ViewDefinition/patient"
* relatedArtifact[dependsOn][+].type = #depends-on
* relatedArtifact[dependsOn][=].resource = "http://example.org/fhir/ViewDefinition/observation"
* content[0].contentType = #"text/sql"
* content[0].title = "BreastScreeningDemo.sql"
* content[0].data = "V0lUSCBhZ2VfYXRfZW5kX29mX3BlcmlvZCBBUyAoU0VMRUNUIHAuaWQgQVMgcGF0aWVudF9pZCwgQ0FTVChzdHJmdGltZSgnJVknLCA6cGVyaW9kX2VuZCkgQVMgSU5URUdFUikgLSBDQVNUKHN0cmZ0aW1lKCclWScsIHAuYmlydGhfZGF0ZSkgQVMgSU5URUdFUikgLSAoc3RyZnRpbWUoJyVtLSVkJywgOnBlcmlvZF9lbmQpIDwgc3RyZnRpbWUoJyVtLSVkJywgcC5iaXJ0aF9kYXRlKSkgQVMgYWdlIEZST00gcGF0aWVudCBwKQ=="
