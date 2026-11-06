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
       'event (list (test-script "pm.test('Status is 200 OK', function () {\n    pm.response.to.have.status(200);\n});\npm.test('Returns 12 patient population rows', function () {\n    var jsonData = pm.response.json();\n    pm.expect(jsonData).to.be.an('array');\n    pm.expect(jsonData.length).to.be.at.least(1);\n});\n\nvar jsonData = pm.response.json();\nvar template = `\n<style>\n  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; padding: 20px; background: #f8fafc; color: #1e293b; }\n  .card { background: white; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }\n  table { width: 100%; border-collapse: collapse; margin-top: 12px; }\n  th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid #e2e8f0; font-size: 14px; }\n  th { background: #f1f5f9; color: #475569; font-weight: 600; }\n  .badge { padding: 4px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }\n  .badge-screened { background: #dcfce7; color: #166534; }\n  .badge-unscreened { background: #fef9c3; color: #854d0e; }\n  .badge-noteligible { background: #f1f5f9; color: #64748b; }\n</style>\n<div class=\"card\">\n  <h3>Patient Cohort Results (SQL on FHIR)</h3>\n  <table>\n    <thead>\n      <tr><th>Patient ID</th><th>Initial Population</th><th>Denominator</th><th>Numerator</th><th>Outcome</th></tr>\n    </thead>\n    <tbody>\n      {{#each rows}}\n      <tr>\n        <td><strong>{{patient_id}}</strong></td>\n        <td>{{initial-population}}</td>\n        <td>{{denominator}}</td>\n        <td>{{numerator}}</td>\n        <td>\n          {{#if (eq numerator 1)}}<span class=\"badge badge-screened\">Screened</span>\n          {{else if (eq denominator 1)}}<span class=\"badge badge-unscreened\">Not Screened</span>\n          {{else}}<span class=\"badge badge-noteligible\">Not Eligible</span>{{/if}}\n        </td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n</div>\n`;\n\npm.visualizer.set(template, { rows: jsonData });"))
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
                               'options (hasheq 'raw (hasheq 'language "json")))))
      (hasheq
       'name "3.4 Generate Summary MeasureReport directly from SQL"
       'event (list (test-script "pm.test('Status is 200 OK', function () {\n    pm.response.to.have.status(200);\n});\npm.test('Returns valid FHIR MeasureReport', function () {\n    var jsonData = pm.response.json();\n    var report = jsonData[0].measure_report || jsonData[0];\n    pm.expect(report.resourceType).to.eql('MeasureReport');\n    pm.expect(report.type).to.eql('summary');\n    pm.expect(report.group[0].population.length).to.eql(3);\n});\n\nvar jsonData = pm.response.json();\nvar r = jsonData[0].measure_report || jsonData[0];\nvar g = r.group[0];\nvar ip = g.population.find(p => p.code.coding[0].code === 'initial-population').count;\nvar denom = g.population.find(p => p.code.coding[0].code === 'denominator').count;\nvar num = g.population.find(p => p.code.coding[0].code === 'numerator').count;\nvar rate = (denom > 0 ? ((num / denom) * 100).toFixed(1) : '0.0');\n\nvar template = `\n<style>\n  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; padding: 24px; background: #f8fafc; color: #1e293b; }\n  .card { background: white; border-radius: 12px; padding: 24px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); margin-bottom: 24px; max-width: 800px; }\n  .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #e2e8f0; padding-bottom: 16px; margin-bottom: 20px; }\n  .title { font-size: 20px; font-weight: 700; color: #0f172a; margin: 0; }\n  .sub { font-size: 13px; color: #64748b; margin-top: 4px; }\n  .stats { display: flex; gap: 16px; margin-bottom: 20px; }\n  .stat-box { flex: 1; padding: 16px; background: #f1f5f9; border-radius: 8px; text-align: center; }\n  .stat-val { font-size: 32px; font-weight: 800; color: #0f172a; }\n  .stat-lbl { font-size: 12px; font-weight: 600; color: #64748b; text-transform: uppercase; margin-top: 4px; }\n  .stat-rate { color: #0284c7; }\n  .badge { background: #dbeafe; color: #1e40af; padding: 4px 10px; border-radius: 12px; font-size: 12px; font-weight: 600; }\n</style>\n<div class=\"card\">\n  <div class=\"header\">\n    <div>\n      <h2 class=\"title\">Breast Cancer Screening (BCS-E)</h2>\n      <div class=\"sub\">Period: {{r.period.start}} &ndash; {{r.period.end}} | Resource: <strong>{{r.resourceType}}</strong></div>\n    </div>\n    <span class=\"badge\">{{r.status}}</span>\n  </div>\n  <div class=\"stats\">\n    <div class=\"stat-box\"><div class=\"stat-val\">{{ip}}</div><div class=\"stat-lbl\">Initial Population</div></div>\n    <div class=\"stat-box\"><div class=\"stat-val\">{{denom}}</div><div class=\"stat-lbl\">Denominator</div></div>\n    <div class=\"stat-box\"><div class=\"stat-val\">{{num}}</div><div class=\"stat-lbl\">Numerator (Screened)</div></div>\n    <div class=\"stat-box\"><div class=\"stat-val stat-rate\">{{rate}}%</div><div class=\"stat-lbl\">Screening Rate</div></div>\n  </div>\n</div>\n`;\n\npm.visualizer.set(template, { r: r, ip: ip, denom: denom, num: num, rate: rate });"))
       'request (hasheq
                 'method "POST"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/$sql")
                 'body (hasheq 'mode "raw"
                               'raw (jsexpr->string (list (string-append
                                                           "WITH params AS (SELECT TIMESTAMPTZ '2025-01-01T00:00:00.000Z' AS period_start, TIMESTAMPTZ '2025-12-31T23:59:59.999Z' AS period_end), "
                                                           "mammography (system, code) AS (VALUES ('http://loinc.org', '24606-6'), ('http://snomed.info/sct', '71651007')), "
                                                           "age_at_end_of_period AS (SELECT p.id AS patient_id, date_part('year', age((params.period_end AT TIME ZONE 'UTC')::date, p.birth_date::date))::int AS age FROM sof.patient p CROSS JOIN params), "
                                                           "initial_population AS (SELECT p.id AS patient_id, COALESCE(p.gender = 'female' AND a.age BETWEEN 42 AND 74, false) AS v FROM sof.patient p JOIN age_at_end_of_period a ON a.patient_id = p.id), "
                                                           "mammograms_during_period AS (SELECT DISTINCT replace(o.patient_id, 'Patient/', '') AS patient_id, o.id FROM sof.observation o JOIN mammography vs ON vs.system = o.code_system AND vs.code = o.code CROSS JOIN params WHERE o.status IN ('final', 'amended', 'corrected') AND o.effective::timestamptz BETWEEN params.period_start AND params.period_end), "
                                                           "numerator AS (SELECT p.id AS patient_id, EXISTS (SELECT 1 FROM mammograms_during_period m WHERE m.patient_id = p.id) AS v FROM sof.patient p), "
                                                           "cohort AS (SELECT ip.patient_id AS patient_id, ip.v::int AS ip, ip.v::int AS denom, (ip.v AND n.v)::int AS numer FROM initial_population ip JOIN numerator n ON n.patient_id = ip.patient_id), "
                                                           "counts AS (SELECT SUM(ip) AS ip_count, SUM(denom) AS denom_count, SUM(numer) AS numer_count, ROUND(SUM(numer)::numeric / NULLIF(SUM(denom), 0), 3) AS score FROM cohort) "
                                                           "SELECT jsonb_build_object("
                                                           "'resourceType', 'MeasureReport', "
                                                           "'status', 'complete', "
                                                           "'type', 'summary', "
                                                           "'measure', 'http://example.org/fhir/Measure/BreastScreeningDemo', "
                                                           "'period', jsonb_build_object('start', '2025-01-01', 'end', '2025-12-31'), "
                                                           "'group', jsonb_build_array(jsonb_build_object("
                                                           "'id', 'BreastScreening', "
                                                           "'population', jsonb_build_array("
                                                           "jsonb_build_object('code', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/measure-population', 'code', 'initial-population'))), 'count', counts.ip_count), "
                                                           "jsonb_build_object('code', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/measure-population', 'code', 'denominator'))), 'count', counts.denom_count), "
                                                           "jsonb_build_object('code', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/measure-population', 'code', 'numerator'))), 'count', counts.numer_count)"
                                                           "), "
                                                           "'measureScore', jsonb_build_object('value', counts.score)"
                                                           "))"
                                                           ") AS measure_report FROM counts;")))
                               'options (hasheq 'raw (hasheq 'language "json")))))
      (hasheq
       'name "3.5 Generate Individual MeasureReports for All Patients"
       'event (list (test-script "pm.test('Status is 200 OK', function () {\n    pm.response.to.have.status(200);\n});\npm.test('Returns individual MeasureReport per patient', function () {\n    var jsonData = pm.response.json();\n    pm.expect(jsonData.length).to.be.at.least(1);\n    pm.expect(jsonData[0].measure_report.type).to.eql('individual');\n});"))
       'request (hasheq
                 'method "POST"
                 'header (list (header "Content-Type" "application/json"))
                 'url (url-obj "/$sql")
                 'body (hasheq 'mode "raw"
                               'raw (jsexpr->string (list (string-append
                                                           "WITH params AS (SELECT TIMESTAMPTZ '2025-01-01T00:00:00.000Z' AS period_start, TIMESTAMPTZ '2025-12-31T23:59:59.999Z' AS period_end), "
                                                           "mammography (system, code) AS (VALUES ('http://loinc.org', '24606-6'), ('http://snomed.info/sct', '71651007')), "
                                                           "age_at_end_of_period AS (SELECT p.id AS patient_id, date_part('year', age((params.period_end AT TIME ZONE 'UTC')::date, p.birth_date::date))::int AS age FROM sof.patient p CROSS JOIN params), "
                                                           "initial_population AS (SELECT p.id AS patient_id, COALESCE(p.gender = 'female' AND a.age BETWEEN 42 AND 74, false) AS v FROM sof.patient p JOIN age_at_end_of_period a ON a.patient_id = p.id), "
                                                           "mammograms_during_period AS (SELECT DISTINCT replace(o.patient_id, 'Patient/', '') AS patient_id, o.id FROM sof.observation o JOIN mammography vs ON vs.system = o.code_system AND vs.code = o.code CROSS JOIN params WHERE o.status IN ('final', 'amended', 'corrected') AND o.effective::timestamptz BETWEEN params.period_start AND params.period_end), "
                                                           "numerator AS (SELECT p.id AS patient_id, EXISTS (SELECT 1 FROM mammograms_during_period m WHERE m.patient_id = p.id) AS v FROM sof.patient p), "
                                                           "cohort AS (SELECT ip.patient_id AS patient_id, ip.v::int AS ip, ip.v::int AS denom, (ip.v AND n.v)::int AS numer FROM initial_population ip JOIN numerator n ON n.patient_id = ip.patient_id) "
                                                           "SELECT jsonb_build_object("
                                                           "'resourceType', 'MeasureReport', "
                                                           "'status', 'complete', "
                                                           "'type', 'individual', "
                                                           "'measure', 'http://example.org/fhir/Measure/BreastScreeningDemo', "
                                                           "'subject', jsonb_build_object('reference', 'Patient/' || c.patient_id), "
                                                           "'period', jsonb_build_object('start', '2025-01-01', 'end', '2025-12-31'), "
                                                           "'group', jsonb_build_array(jsonb_build_object("
                                                           "'id', 'BreastScreening', "
                                                           "'population', jsonb_build_array("
                                                           "jsonb_build_object('code', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/measure-population', 'code', 'initial-population'))), 'count', c.ip), "
                                                           "jsonb_build_object('code', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/measure-population', 'code', 'denominator'))), 'count', c.denom), "
                                                           "jsonb_build_object('code', jsonb_build_object('coding', jsonb_build_array(jsonb_build_object('system', 'http://terminology.hl7.org/CodeSystem/measure-population', 'code', 'numerator'))), 'count', c.numer)"
                                                           ")))"
                                                           ") AS measure_report FROM cohort c ORDER BY c.patient_id;")))
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
