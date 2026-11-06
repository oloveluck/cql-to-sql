#lang racket/base

;;; spec.rkt — the relational model, as data, and the SQL-on-FHIR ViewDefinitions it generates.
;;;
;;; The model is what BCS-E's cohort definition reads (PLAN.md R1), flattened by the rules of R2:
;;; one table per resource type, a child table per repeating element, every row keyed to its source
;;; resource and patient, paths in FHIR R6 (data arrives R4 and is converted, r4-to-r6.rkt).
;;;
;;; A Col is (col name path type): a column, its FHIRPath (R6, relative to the row's element) and
;;;   its SQL-on-FHIR type ("string" "date" "dateTime" "boolean" "integer" "decimal" "code" …).
;;; A Table is (table name resource levels cols):
;;;   levels : (listof String)  the forEach paths from the resource down to the row's element; '()
;;;            for a base table (one row per resource)
;;;   cols   : (listof Col)     the row's own columns
;;; Every table also gets, generated: `<base>_id` (the resource's key), `patient_id` (where the
;;; resource has a patient), and `<level>_idx` (the element's position, %rowIndex) per level; a
;;; base table gets `data_source` (the HEDIS data-source tag). So a row traces back to its source.

(require racket/contract
         racket/list
         racket/match
         racket/string
         racket/file
         json)

(provide
 (struct-out col)
 (struct-out table)
 (contract-out
  [model (listof table?)]
  [table->view (-> table? hash?)]
  [table-columns (-> table? (listof string?))]
  [table-column-types (-> table? (listof string?))]
  [schema-markdown (-> string?)]
  [base-name (-> string? string?)]
  [write-views! (-> path-string? void?)]))

(struct col (name path type) #:transparent)
(struct table (name resource levels cols) #:transparent)

;; ---- per-resource facts ------------------------------------------------------------------------

;; base-name : ResourceType -> String   the base table's name, prefix of its children
(define base-names
  (hash "Patient" "patient" "Coverage" "coverage" "Claim" "claim" "ExplanationOfBenefit" "eob"
        "Encounter" "encounter" "Procedure" "procedure" "Condition" "condition" "Observation" "observation"
        "DiagnosticReport" "diagnostic_report" "MedicationDispense" "medication_dispense"
        "Medication" "medication" "Practitioner" "practitioner" "PractitionerRole" "practitioner_role"
        "Location" "location"))
(define (base-name t) (hash-ref base-names t))

;; the R6 path to the patient a resource is about (#f: not patient data)
(define patient-paths
  (hash "Patient" "getResourceKey()"
        "Coverage" "beneficiary.getReferenceKey(Patient)"
        "Claim" "subject.getReferenceKey(Patient)" "ExplanationOfBenefit" "subject.getReferenceKey(Patient)"
        "Encounter" "subject.getReferenceKey(Patient)" "Procedure" "subject.getReferenceKey(Patient)"
        "Condition" "subject.getReferenceKey(Patient)" "Observation" "subject.getReferenceKey(Patient)"
        "DiagnosticReport" "subject.getReferenceKey(Patient)" "MedicationDispense" "subject.getReferenceKey(Patient)"))

(define data-source-path
  "meta.tag.where(system = 'https://ncqa.org/fhir/CodeSystem/hedis-data-source').code.first()")

;; ---- column shorthands ---------------------------------------------------------------------------

(define (s name path) (col name path "string"))
(define (c name path) (col name path "code"))
(define (d name path) (col name path "date"))
(define (dt name path) (col name path "dateTime"))
(define (b name path) (col name path "boolean"))
(define (i name path) (col name path "integer"))
(define (n name path) (col name path "decimal"))
(define (ref name path type) (col name (format "~a.getReferenceKey(~a)" path type) "string"))
;; a date-or-period choice element: <name>_date|_datetime, _start, _end
(define (when-cols name path #:date-type [date-type "dateTime"])
  (list (col (format "~a_~a" name (if (equal? date-type "date") "date" "datetime")) (format "~a.ofType(~a)" path date-type) date-type)
        (dt (format "~a_start" name) (format "~a.ofType(Period).start" path))
        (dt (format "~a_end" name) (format "~a.ofType(Period).end" path))))
(define (period-cols name path)
  (list (dt (format "~a_start" name) (format "~a.start" path)) (dt (format "~a_end" name) (format "~a.end" path))))

(define coding-cols (list (s "system" "system") (c "code" "code") (s "display" "display")))

;; codings : name resource levels -> Table   a child over a CodeableConcept's codings
(define (codings name resource levels) (table name resource levels coding-cols))

;; extension-cols : the value[x] of an extension, by type
(define extension-cols
  (list (s "url" "url")
        (b "value_boolean" "value.ofType(boolean)")
        (s "value_string" "value.ofType(string)")
        (c "value_code" "value.ofType(code)")
        (i "value_integer" "value.ofType(integer)")
        (dt "value_datetime" "value.ofType(dateTime)")
        (d "value_date" "value.ofType(date)")
        (s "value_coding_system" "value.ofType(Coding).system")
        (c "value_coding_code" "value.ofType(Coding).code")
        (s "value_concept_system" "value.ofType(CodeableConcept).coding.first().system")
        (c "value_concept_code" "value.ofType(CodeableConcept).coding.first().code")
        (dt "value_period_start" "value.ofType(Period).start")
        (dt "value_period_end" "value.ofType(Period).end")))

;; extensions : base resource -> (listof Table)   a resource's extensions, and their nested parts
(define (extensions resource)
  (define bn (base-name resource))
  (list (table (format "~a_extension" bn) resource '("extension") extension-cols)
        (table (format "~a_extension_part" bn) resource '("extension" "extension") extension-cols)))

;; claim-like : the tables of a Claim or an ExplanationOfBenefit (the same shape for what BCS-E reads)
(define (claim-like resource)
  (define bn (base-name resource))
  (define (t suffix levels cols) (table (format "~a_~a" bn suffix) resource levels cols))
  (define (cc suffix levels) (codings (format "~a_~a" bn suffix) resource levels))
  (append
   (list (table bn resource '()
                (append (list (c "status" "status") (c "use" "use"))
                        (if (equal? resource "ExplanationOfBenefit") (list (c "outcome" "outcome")) '())
                        (period-cols "billable_period" "billablePeriod")))
         (cc "type_coding" '("type.coding"))
         (t "care_team" '("careTeam") (list (i "sequence" "sequence") (ref "provider_id" "provider" "Practitioner")))
         (t "diagnosis" '("diagnosis") (list (i "sequence" "sequence") (ref "condition_id" "diagnosis.ofType(Reference)" "Condition")))
         (cc "diagnosis_coding" '("diagnosis" "diagnosis.ofType(CodeableConcept).coding"))
         (cc "diagnosis_type_coding" '("diagnosis" "type.coding"))
         (t "procedure" '("procedure") (append (list (i "sequence" "sequence") (ref "procedure_id" "procedure.ofType(Reference)" "Procedure"))
                                               (list (dt "date" "date"))))
         (cc "procedure_coding" '("procedure" "procedure.ofType(CodeableConcept).coding"))
         (t "supporting_info" '("supportingInfo") (list (i "sequence" "sequence")))
         (cc "supporting_info_category_coding" '("supportingInfo" "category.coding"))
         (cc "supporting_info_code_coding" '("supportingInfo" "code.coding"))
         (t "item" '("item") (append (list (i "sequence" "sequence"))
                                     (when-cols "serviced" "serviced" #:date-type "date")
                                     (list (n "quantity_value" "quantity.value"))))
         (cc "item_product_or_service_coding" '("item" "productOrService.coding"))
         (cc "item_modifier_coding" '("item" "modifier.coding"))
         (cc "item_revenue_coding" '("item" "revenue.coding"))
         (cc "item_location_coding" '("item" "location.ofType(CodeableConcept).coding"))
         (t "item_diagnosis_sequence" '("item" "diagnosisSequence") (list (i "value" "$this")))
         (t "item_procedure_sequence" '("item" "procedureSequence") (list (i "value" "$this")))
         (t "item_information_sequence" '("item" "informationSequence") (list (i "value" "$this"))))
   (if (equal? resource "ExplanationOfBenefit")
       (list (t "item_adjudication" '("item" "adjudication") (list (n "amount_value" "amount.value") (c "amount_currency" "amount.currency")))
             (cc "item_adjudication_category_coding" '("item" "adjudication" "category.coding")))
       '())))

;; ---- the model -----------------------------------------------------------------------------------

(define model
  (append
   ;; Patient
   (list (table "patient" "Patient" '()
                (list (c "gender" "gender") (d "birth_date" "birthDate")
                      (b "deceased_boolean" "deceased.ofType(boolean)") (dt "deceased_datetime" "deceased.ofType(dateTime)")))
         (table "patient_communication" "Patient" '("communication")
                (list (s "language_system" "language.coding.first().system") (c "language_code" "language.coding.first().code")
                      (b "preferred" "preferred"))))
   (extensions "Patient")
   ;; Coverage
   (list (table "coverage" "Coverage" '() (append (list (c "status" "status")) (period-cols "period" "period")))
         (codings "coverage_type_coding" "Coverage" '("type.coding")))
   (extensions "Coverage")
   ;; Claim, ExplanationOfBenefit
   (claim-like "Claim")
   (claim-like "ExplanationOfBenefit")
   ;; Encounter (R6: class 0..*, actualPeriod, diagnosis.condition CodeableReference, participant.actor)
   (list (table "encounter" "Encounter" '()
                (append (list (c "status" "status")
                              (c "status_r4" (format "extension('~a').value.ofType(code)" "http://hl7.org/fhir/4.0/StructureDefinition/extension-Encounter.status")))
                        (period-cols "period" "actualPeriod")))
         (codings "encounter_class_coding" "Encounter" '("class.coding"))
         (codings "encounter_type_coding" "Encounter" '("type.coding"))
         (table "encounter_diagnosis" "Encounter" '("diagnosis")
                (list (ref "condition_id" "condition.reference" "Condition")
                      (i "rank" (format "extension('~a').value.ofType(positiveInt)" "http://hl7.org/fhir/4.0/StructureDefinition/extension-Encounter.diagnosis.rank"))))
         (codings "encounter_diagnosis_condition_coding" "Encounter" '("diagnosis" "condition.concept.coding"))
         (codings "encounter_diagnosis_use_coding" "Encounter" '("diagnosis" "use.coding"))
         (table "encounter_participant" "Encounter" '("participant") (list (ref "practitioner_id" "actor" "Practitioner"))))
   ;; Procedure (R6: occurrence[x], outcome and reason as CodeableReference)
   (list (table "procedure" "Procedure" '()
                (append (list (c "status" "status") (ref "encounter_id" "encounter" "Encounter"))
                        (when-cols "performed" "occurrence")))
         (codings "procedure_code_coding" "Procedure" '("code.coding"))
         (codings "procedure_status_reason_coding" "Procedure" '("statusReason.coding"))
         (codings "procedure_body_site_coding" "Procedure" '("bodySite" "coding"))
         (codings "procedure_outcome_coding" "Procedure" '("outcome" "concept.coding"))
         (codings "procedure_reason_coding" "Procedure" '("reason" "concept.coding"))
         (table "procedure_reason_reference" "Procedure" '("reason") (list (s "reference" "reference.reference"))))
   ;; Condition
   (list (table "condition" "Condition" '()
                (append (list (c "clinical_status" "clinicalStatus.coding.first().code")
                              (c "verification_status" "verificationStatus.coding.first().code")
                              (dt "recorded_date" "recordedDate"))
                        (when-cols "onset" "onset") (when-cols "abatement" "abatement")))
         (codings "condition_code_coding" "Condition" '("code.coding"))
         (codings "condition_category_coding" "Condition" '("category" "coding")))
   ;; Observation
   (list (table "observation" "Observation" '()
                (append (list (c "status" "status"))
                        (when-cols "effective" "effective")
                        (list (n "value_quantity_value" "value.ofType(Quantity).value") (s "value_quantity_unit" "value.ofType(Quantity).code")
                              (s "value_string" "value.ofType(string)") (b "value_boolean" "value.ofType(boolean)")
                              (i "value_integer" "value.ofType(integer)") (dt "value_datetime" "value.ofType(dateTime)"))))
         (codings "observation_code_coding" "Observation" '("code.coding"))
         (codings "observation_value_coding" "Observation" '("value.ofType(CodeableConcept).coding"))
         (codings "observation_category_coding" "Observation" '("category" "coding")))
   ;; DiagnosticReport
   (list (table "diagnostic_report" "DiagnosticReport" '() (append (list (c "status" "status")) (when-cols "effective" "effective")))
         (codings "diagnostic_report_code_coding" "DiagnosticReport" '("code.coding"))
         (codings "diagnostic_report_category_coding" "DiagnosticReport" '("category" "coding")))
   ;; MedicationDispense (R6: medication CodeableReference), Medication (R6: packageSize.amountPerItem)
   (list (table "medication_dispense" "MedicationDispense" '()
                (list (c "status" "status") (dt "when_handed_over" "whenHandedOver")
                      (n "days_supply_value" "daysSupply.value") (n "quantity_value" "quantity.value")
                      (ref "medication_id" "medication.reference" "Medication")))
         (codings "medication_dispense_medication_coding" "MedicationDispense" '("medication.concept.coding"))
         (table "medication" "Medication" '()
                (list (n "amount_numerator_value" "packageSize.amountPerItem.numerator.value")
                      (s "amount_numerator_unit" "packageSize.amountPerItem.numerator.code")
                      (n "amount_denominator_value" "packageSize.amountPerItem.denominator.value")))
         (codings "medication_code_coding" "Medication" '("code.coding")))
   ;; Practitioner, PractitionerRole, Location
   (list (table "practitioner" "Practitioner" '() '())
         (table "practitioner_identifier" "Practitioner" '("identifier") (list (s "system" "system") (s "value" "value")))
         (table "practitioner_role" "PractitionerRole" '() (list (ref "practitioner_id" "practitioner" "Practitioner")))
         (codings "practitioner_role_code_coding" "PractitionerRole" '("code" "coding"))
         (codings "practitioner_role_specialty_coding" "PractitionerRole" '("specialty" "coding")))
   (extensions "PractitionerRole")
   (list (table "location" "Location" '() '())
         (table "location_identifier" "Location" '("identifier") (list (s "system" "system") (s "value" "value")))
         (codings "location_type_coding" "Location" '("type" "coding")))))

;; ---- ViewDefinitions -------------------------------------------------------------------------------

;; snake : String -> String   "productOrService.coding" -> "product_or_service"
(define (snake path)
  (define head (car (string-split (car (regexp-match #px"^[A-Za-z$]+" path)) ".")))
  (string-downcase (regexp-replace* #px"([a-z])([A-Z])" (if (equal? head "$this") "value" head) "\\1_\\2")))

;; level-idx-names : (listof String) -> (listof String)   the idx column per level, unique
(define (level-idx-names levels)
  (let loop ([ls levels] [seen '()])
    (cond [(null? ls) '()]
          [else (define base (format "~a_idx" (snake (car ls))))
                (define name (if (member base seen) (format "~a~a_idx" (snake (car ls)) (add1 (count (lambda (x) (equal? x base)) seen))) base))
                (cons name (loop (cdr ls) (cons base seen)))])))

;; table-columns : Table -> (listof String)   the generated and declared columns, in order
(define (table-columns t)
  (define r (table-resource t))
  (append (list (format "~a_id" (base-name r)))
          (if (hash-ref patient-paths r #f) (if (equal? r "Patient") '() (list "patient_id")) '())
          (if (null? (table-levels t)) (list "data_source") '())
          (level-idx-names (table-levels t))
          (map col-name (table-cols t))))

(define (col->json x) (hasheq 'name (col-name x) 'path (col-path x) 'type (col-type x)))

;; table-column-types : Table -> (listof String)   the SQL type of each column, as table-columns
;; orders them: dates stay TEXT (CQL compares at the precision written)
(define (sql-type t)
  (case t [("boolean" "integer") "INTEGER"] [("decimal") "REAL"] [else "TEXT"]))
(define (table-column-types t)
  (define generated (- (length (table-columns t)) (length (table-cols t))))
  (append (for/list ([c (take (table-columns t) generated)]) (if (regexp-match? #rx"_idx$" c) "INTEGER" "TEXT"))
          (map (lambda (x) (sql-type (col-type x))) (table-cols t))))

;; schema-markdown : -> String   the model as a data dictionary: every table, its source, its columns
(define (schema-markdown)
  (string-append
   "# The relational model (generated by model/spec.rkt; do not edit)\n\n"
   "One table per resource type and a child table per repeating element, from FHIR R6. Every row "
   "carries its resource's key (`<base>_id`), `patient_id` where the resource is patient data, and "
   "`<level>_idx` per repeating level (the element's position). Dates are ISO text as written.\n\n"
   (apply string-append
          (for/list ([t model])
            (define generated (- (length (table-columns t)) (length (table-cols t))))
            (string-append
             (format "## `~a`\n\n~a~a\n\n| Column | Type | FHIRPath (R6) |\n|---|---|---|\n"
                     (table-name t) (table-resource t)
                     (if (null? (table-levels t)) ", one row per resource" (format ", one row per `~a`" (string-join (table-levels t) " → "))))
             (apply string-append
                    (for/list ([c (take (table-columns t) generated)])
                      (format "| `~a` | ~a | ~a |\n" c (if (regexp-match? #rx"_idx$" c) "INTEGER" "TEXT")
                              (cond [(regexp-match? #rx"_idx$" c) "position (`%rowIndex`)"]
                                    [(equal? c "patient_id") (format "`~a`" (hash-ref patient-paths (table-resource t)))]
                                    [(equal? c "data_source") "HEDIS data-source tag"]
                                    [else "`getResourceKey()`"]))))
             (apply string-append
                    (for/list ([x (table-cols t)])
                      (format "| `~a` | ~a | `~a` |\n" (col-name x) (sql-type (col-type x)) (col-path x))))
             "\n")))))

;; table->view : Table -> ViewDefinition jsexpr
(define (table->view t)
  (define r (table-resource t))
  (define pp (hash-ref patient-paths r #f))
  (define top
    (append (list (hasheq 'name (format "~a_id" (base-name r)) 'path "getResourceKey()" 'type "id"))
            (if (and pp (not (equal? r "Patient"))) (list (hasheq 'name "patient_id" 'path pp 'type "string")) '())
            (if (null? (table-levels t)) (list (hasheq 'name "data_source" 'path data-source-path 'type "code")) '())
            (if (null? (table-levels t)) (map col->json (table-cols t)) '())))
  ;; nested forEach per level, the declared columns at the innermost
  (define (nest levels idx-names)
    (match* (levels idx-names)
      [((list l) (list ix))
       (hasheq 'forEach l 'column (cons (hasheq 'name ix 'path "%rowIndex" 'type "integer") (map col->json (table-cols t))))]
      [((cons l more) (cons ix more-ix))
       (hasheq 'forEach l 'column (list (hasheq 'name ix 'path "%rowIndex" 'type "integer"))
               'select (list (nest more more-ix)))]))
  (hasheq 'resourceType "ViewDefinition"
          'name (table-name t)
          'status "active"
          'resource r
          'select (if (null? (table-levels t))
                      (list (hasheq 'column top))
                      (list (hasheq 'column top) (nest (table-levels t) (level-idx-names (table-levels t)))))))

;; write-views! : Dir -> Void   one <name>.json ViewDefinition per table
(define (write-views! dir)
  (make-directory* dir)
  (for ([t model])
    (call-with-output-file (build-path dir (string-append (table-name t) ".json")) #:exists 'truncate
      (lambda (o) (write-json (table->view t) o #:indent 2) (newline o)))))

(module+ main
  (require racket/runtime-path)
  (define-runtime-path views-dir "views")
  (define-runtime-path schema-file "SCHEMA.md")
  (write-views! views-dir)
  (call-with-output-file schema-file #:exists 'truncate (lambda (o) (display (schema-markdown) o)))
  (printf "~a ViewDefinitions written to ~a, data dictionary to ~a\n" (length model) views-dir schema-file))

(module+ test
  (require rackunit)
  (check-equal? (snake "productOrService.coding") "product_or_service")
  (check-equal? (snake "$this") "value")
  (check-equal? (level-idx-names '("item" "adjudication" "category.coding")) '("item_idx" "adjudication_idx" "category_idx"))
  (check-equal? (level-idx-names '("extension" "extension")) '("extension_idx" "extension2_idx"))
  ;; table names are unique, and every table's columns are
  (check-equal? (length (remove-duplicates (map table-name model))) (length model))
  (for ([t model]) (check-equal? (length (remove-duplicates (table-columns t))) (length (table-columns t)) (table-name t)))
  (check-equal? (table-columns (findf (lambda (t) (equal? (table-name t) "claim_item_product_or_service_coding")) model))
                '("claim_id" "patient_id" "item_idx" "product_or_service_idx" "system" "code" "display")))
