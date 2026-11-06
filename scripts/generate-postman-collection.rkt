#lang racket/base

(require json
         racket/file
         racket/string)

(define aidbox-bundle (call-with-input-file "demo/aidbox-load.json" read-json))
(define patient-view (call-with-input-file "demo/views/patient.json" read-json))
(define obs-view (call-with-input-file "demo/views/observation.json" read-json))
(define measure-json (call-with-input-file "demo/measure.json" read-json))
(define sql-text (string-trim (file->string "demo/BreastScreeningDemo.postgres.sql")))

(define (header k v) (hasheq 'key k 'value v 'type "text"))
(define (url-obj path [query '()])
  (hasheq 'raw (string-append "{{aidbox_url}}" path)
          'host (list "{{aidbox_url}}")
          'path (string-split (string-trim path "/") "/")
          'query query))

(define (test-script code)
  (hasheq 'listen "test"
          'script (hasheq 'type "text/javascript"
                          'exec (string-split code "\n"))))

(define collection
  (hasheq
   'info (hasheq 'name "CQL-to-SQL on FHIR (Aidbox)"
                 '_postman_id "cql-to-sql-aidbox-collection"
                 'description "Execute CQL translated SQL queries and SQL-on-FHIR ViewDefinitions inside Aidbox."
                 'schema "https://schema.getpostman.com/json/collection/v2.1.0/collection.json")
   'auth (hasheq 'type "apikey"
                 'apikey (list (hasheq 'key "Authorization" 'value "{{auth_header}}" 'type "string")
                               (hasheq 'key "in" 'value "header" 'type "string")))
   'item
   (list
    ;; Folder 1: Setup & Data Loading
    (hasheq
     'name "1. Setup & Data Loading"
     'item
     (list
      (hasheq
       'name "1.1 Load Complete Demo Bundle (One-Shot Transaction)"
       'event (list (test-script "pm.test('Status is 200 OK', function () {\n    pm.response.to.have.status(200);\n});"))
       'request (hasheq
                 'method "POST"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/fhir")
                 'body (hasheq 'mode "raw" 'raw (jsexpr->string aidbox-bundle)
                               'options (hasheq 'raw (hasheq 'language "json")))))
      (hasheq
       'name "1.2 Create Patient ViewDefinition"
       'request (hasheq
                 'method "PUT"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/fhir/ViewDefinition/demo-patient")
                 'body (hasheq 'mode "raw" 'raw (jsexpr->string patient-view)
                               'options (hasheq 'raw (hasheq 'language "json")))))
      (hasheq
       'name "1.3 Create Observation ViewDefinition"
       'request (hasheq
                 'method "PUT"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/fhir/ViewDefinition/demo-observation")
                 'body (hasheq 'mode "raw" 'raw (jsexpr->string obs-view)
                               'options (hasheq 'raw (hasheq 'language "json")))))))

    ;; Folder 2: Materialize Views
    (hasheq
     'name "2. Materialize SQL-on-FHIR Views"
     'item
     (list
      (hasheq
       'name "2.1 Materialize sof.patient View"
       'event (list (test-script "pm.test('Materialize patient view succeeded', function () {\n    pm.expect(pm.response.code).to.be.oneOf([200, 201]);\n});"))
       'request (hasheq
                 'method "POST"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/fhir/ViewDefinition/demo-patient/$materialize")
                 'body (hasheq 'mode "raw" 'raw "{\n  \"resourceType\": \"Parameters\",\n  \"parameter\": [\n    {\n      \"name\": \"type\",\n      \"valueCode\": \"view\"\n    }\n  ]\n}"
                               'options (hasheq 'raw (hasheq 'language "json")))))
      (hasheq
       'name "2.2 Materialize sof.observation View"
       'event (list (test-script "pm.test('Materialize observation view succeeded', function () {\n    pm.expect(pm.response.code).to.be.oneOf([200, 201]);\n});"))
       'request (hasheq
                 'method "POST"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/fhir/ViewDefinition/demo-observation/$materialize")
                 'body (hasheq 'mode "raw" 'raw "{\n  \"resourceType\": \"Parameters\",\n  \"parameter\": [\n    {\n      \"name\": \"type\",\n      \"valueCode\": \"view\"\n    }\n  ]\n}"
                               'options (hasheq 'raw (hasheq 'language "json")))))))

    ;; Folder 3: Run SQL Queries ($sql)
    (hasheq
     'name "3. Run SQL Queries ($sql)"
     'item
     (list
      (hasheq
       'name "3.1 Run BreastScreening Measure SQL"
       'event (list (test-script "pm.test('Status is 200 OK', function () {\n    pm.response.to.have.status(200);\n});\npm.test('Returns 12 patient population rows', function () {\n    var jsonData = pm.response.json();\n    pm.expect(jsonData).to.be.an('array');\n    pm.expect(jsonData.length).to.eql(12);\n});"))
       'request (hasheq
                 'method "POST"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/$sql")
                 'body (hasheq 'mode "raw"
                               'raw (jsexpr->string (list sql-text))
                               'options (hasheq 'raw (hasheq 'language "json")))))
      (hasheq
       'name "3.2 Query Materialized sof.patient View"
       'request (hasheq
                 'method "POST"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/$sql")
                 'body (hasheq 'mode "raw"
                               'raw (jsexpr->string (list "SELECT * FROM sof.patient ORDER BY id;"))
                               'options (hasheq 'raw (hasheq 'language "json")))))
      (hasheq
       'name "3.3 Query Materialized sof.observation View"
       'request (hasheq
                 'method "POST"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/$sql")
                 'body (hasheq 'mode "raw"
                               'raw (jsexpr->string (list "SELECT * FROM sof.observation ORDER BY id;"))
                               'options (hasheq 'raw (hasheq 'language "json")))))))

    ;; Folder 4: FHIR Measure Evaluation (Optional / Server-dependent)
    (hasheq
     'name "4. FHIR Measure Evaluation (Optional / CQL Engine)"
     'description "Note: Standard Aidbox does not have a built-in $evaluate-measure CQL engine. Use Folder 3 (POST /$sql) for native Aidbox SQL-on-FHIR measure evaluation. This folder is for FHIR servers with a dedicated CQL engine plugin."
     'item
     (list
      (hasheq
       'name "4.1 Create Measure Resource"
       'request (hasheq
                 'method "PUT"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/fhir/Measure/BreastScreeningDemo")
                 'body (hasheq 'mode "raw" 'raw (jsexpr->string measure-json)
                               'options (hasheq 'raw (hasheq 'language "json")))))
      (hasheq
       'name "4.2 Evaluate Measure (Summary - Server Dependent)"
       'event (list (test-script "pm.test('MeasureReport is summary', function () {\n    var jsonData = pm.response.json();\n    pm.expect(jsonData.resourceType).to.eql('MeasureReport');\n    pm.expect(jsonData.type).to.eql('summary');\n});"))
       'request (hasheq
                 'method "GET"
                 'url (url-obj "/fhir/Measure/BreastScreeningDemo/$evaluate-measure"
                               (list (hasheq 'key "periodStart" 'value "{{period_start}}")
                                     (hasheq 'key "periodEnd" 'value "{{period_end}}")))))
      (hasheq
       'name "4.3 Evaluate Measure (Individual - Server Dependent)"
       'event (list (test-script "pm.test('MeasureReport is individual', function () {\n    var jsonData = pm.response.json();\n    pm.expect(jsonData.resourceType).to.eql('MeasureReport');\n    pm.expect(jsonData.type).to.eql('individual');\n});"))
       'request (hasheq
                 'method "GET"
                 'url (url-obj "/fhir/Measure/BreastScreeningDemo/$evaluate-measure"
                               (list (hasheq 'key "subject" 'value "Patient/p01-numerator")
                                     (hasheq 'key "periodStart" 'value "{{period_start}}")
                                     (hasheq 'key "periodEnd" 'value "{{period_end}}"))))))))))

(call-with-output-file "postman/cql-to-sql-aidbox.postman_collection.json" #:exists 'truncate
  (lambda (o)
    (write-json collection o #:indent 2)
    (newline o)))

(printf "Postman collection generated successfully: postman/cql-to-sql-aidbox.postman_collection.json\n")
