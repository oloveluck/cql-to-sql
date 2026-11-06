// Extensions for binding ViewDefinition columns to CQL properties

Extension: CqlViewColumnBinding
Id: cql-view-column-binding
Title: "CQL View Column Binding"
Description: "Binds a SQL-on-FHIR ViewDefinition column to a CQL model property path."
* value[x] only string
* ^context[0].type = #element
* ^context[=].expression = "ViewDefinition.select.column"
