#lang racket/base

;;; r4-to-r6.rkt — FHIR R4 resources as R6, for the elements the relational model reads.
;;;
;;; The model is R6 (PLAN.md, R3); the data and the CQL are R4. This converts only the elements a
;;; measure reads that R6 renamed, retyped or recoded, and passes everything else through. Where
;;; R6 has no exact counterpart, the R4 value is kept in HL7's cross-version extension
;;; (http://hl7.org/fhir/4.0/StructureDefinition/extension-<path>), so the conversion is lossless:
;;; r6->r4 inverts r4->r6, which the tests check over whole corpora.
;;;
;;; A Resource is a jsexpr hash (symbol keys), as read by `json`.
;;; A Rule is (rule type forward backward): for resources of `type`, forward : R4 -> R6 and
;;; backward : R6 -> R4, each a Resource -> Resource function. Rules live in a registry by type.
;;;
;;; Converted (checked against the R4 and R6 core packages):
;;;   Encounter.class (Coding 0..1)            -> class (CodeableConcept 0..*)
;;;   Encounter.period                         -> actualPeriod
;;;   Encounter.status finished/arrived/…      -> completed/in-progress/on-hold (R4 code kept when lossy)
;;;   Encounter.diagnosis.condition (Reference)-> condition (CodeableReference 0..*)
;;;   Encounter.diagnosis.use (0..1)           -> use (0..*)
;;;   Encounter.diagnosis.rank                 -> cross-version extension
;;;   Encounter.participant.individual         -> actor
;;;   Procedure.performed[x]                   -> occurrence[x]
;;;   Procedure.outcome (CodeableConcept)      -> outcome (CodeableReference 0..*)
;;;   Procedure.reasonCode / reasonReference   -> reason (CodeableReference 0..*)
;;;   MedicationDispense.medication[x]         -> medication (CodeableReference)
;;;   MedicationDispense.status stopped        -> unfulfilled
;;;   Medication.amount (Ratio)                -> packageSize.amountPerItem (Ratio)
;;;   Claim.patient, ExplanationOfBenefit.patient -> subject

(require racket/contract
         racket/list
         racket/match
         racket/string)

(provide
 (contract-out
  [r4->r6 (-> hash? hash?)]
  [r6->r4 (-> hash? hash?)]
  [xver-url (-> string? string?)]
  [encounter-status-r4->r6 (-> string? string?)]
  [converted-types (listof string?)]))

(struct rule (type forward backward))

;; xver-url : String -> String   the cross-version extension for an R4 element path
(define (xver-url path) (string-append "http://hl7.org/fhir/4.0/StructureDefinition/extension-" path))

;; ---- helpers over jsexpr hashes --------------------------------------------------------------

;; rename : Resource Symbol Symbol -> Resource   move key `from` to `to`, if present
(define (rename h from to)
  (if (hash-has-key? h from) (hash-set (hash-remove h from) to (hash-ref h from)) h))

;; update-each : Resource Symbol (Hash -> Hash) -> Resource   f over each element of the list at key
(define (update-each h key f)
  (if (list? (hash-ref h key #f)) (hash-set h key (map f (hash-ref h key))) h))

;; set-or-drop : Resource Symbol Any -> Resource   set key, or remove it when the value is '() or #f
(define (set-or-drop h key v)
  (if (or (not v) (null? v)) (hash-remove h key) (hash-set h key v)))

;; add-ext / take-ext : the extension `url` on an element: add one, or remove it and return its value
(define (add-ext h url value-key value)
  (hash-set h 'extension (append (hash-ref h 'extension '()) (list (hasheq 'url url value-key value)))))
(define (take-ext h url value-key)
  (define exts (hash-ref h 'extension '()))
  (define hit (findf (lambda (e) (equal? (hash-ref e 'url #f) url)) exts))
  (if hit
      (values (set-or-drop h 'extension (remove hit exts)) (hash-ref hit value-key #f))
      (values h #f)))

;; choice keys: performedDateTime … -> occurrenceDateTime …
(define (rename-choice h from to)
  (for/fold ([h h]) ([k (in-list (hash-keys h))])
    (define s (symbol->string k))
    (if (and (string-prefix? s from) (> (string-length s) (string-length from))
             (char-upper-case? (string-ref s (string-length from))))
        (rename h k (string->symbol (string-append to (substring s (string-length from)))))
        h)))

;; ---- Encounter ---------------------------------------------------------------------------------

;; R4 codes R6 dropped map to their nearest R6 code; the lossy ones keep the R4 code in an extension
(define encounter-status-map
  (hash "finished" "completed" "arrived" "in-progress" "triaged" "in-progress" "onleave" "on-hold"))
(define encounter-status-lossy '("arrived" "triaged" "onleave"))
(define (encounter-status-r4->r6 s) (hash-ref encounter-status-map s s))
(define encounter-status-back (hash "completed" "finished" "on-hold" "onleave"))
(define status-ext (xver-url "Encounter.status"))
(define rank-ext (xver-url "Encounter.diagnosis.rank"))

(define (encounter-forward r)
  (define st (hash-ref r 'status #f))
  (let* ([r (if (hash? (hash-ref r 'class #f)) (hash-set r 'class (list (hasheq 'coding (list (hash-ref r 'class))))) r)]
         [r (rename r 'period 'actualPeriod)]
         [r (if (and st (member st encounter-status-lossy)) (add-ext r status-ext 'valueCode st) r)]
         [r (if st (hash-set r 'status (encounter-status-r4->r6 st)) r)]
         [r (update-each r 'diagnosis
                         (lambda (d)
                           (let* ([d (if (hash? (hash-ref d 'condition #f)) (hash-set d 'condition (list (hasheq 'reference (hash-ref d 'condition)))) d)]
                                  [d (if (hash? (hash-ref d 'use #f)) (hash-set d 'use (list (hash-ref d 'use))) d)]
                                  [d (if (hash-has-key? d 'rank) (add-ext (hash-remove d 'rank) rank-ext 'valuePositiveInt (hash-ref d 'rank)) d)])
                             d)))]
         [r (update-each r 'participant (lambda (p) (rename p 'individual 'actor)))])
    r))

(define (encounter-backward r)
  (define-values (r1 st-r4) (take-ext r status-ext 'valueCode))
  (let* ([r r1]
         [r (match (hash-ref r 'class #f)
              [(list (hash-table ('coding (list c)))) (hash-set r 'class c)]
              [_ r])]
         [r (rename r 'actualPeriod 'period)]
         [r (cond [st-r4 (hash-set r 'status st-r4)]
                  [(hash-ref r 'status #f) => (lambda (s) (hash-set r 'status (hash-ref encounter-status-back s s)))]
                  [else r])]
         [r (update-each r 'diagnosis
                         (lambda (d)
                           (define-values (d1 rank) (take-ext d rank-ext 'valuePositiveInt))
                           (let* ([d d1]
                                  [d (match (hash-ref d 'condition #f)
                                       [(list (hash-table ('reference ref))) (hash-set d 'condition ref)]
                                       [_ d])]
                                  [d (match (hash-ref d 'use #f) [(list u) (hash-set d 'use u)] [_ d])]
                                  [d (if rank (hash-set d 'rank rank) d)])
                             d)))]
         [r (update-each r 'participant (lambda (p) (rename p 'actor 'individual)))])
    r))

;; ---- Procedure ---------------------------------------------------------------------------------

(define (procedure-forward r)
  (let* ([r (rename-choice r "performed" "occurrence")]
         [r (if (hash? (hash-ref r 'outcome #f)) (hash-set r 'outcome (list (hasheq 'concept (hash-ref r 'outcome)))) r)]
         [reasons (append (for/list ([c (hash-ref r 'reasonCode '())]) (hasheq 'concept c))
                          (for/list ([x (hash-ref r 'reasonReference '())]) (hasheq 'reference x)))]
         [r (set-or-drop (hash-remove (hash-remove r 'reasonCode) 'reasonReference) 'reason reasons)])
    r))

(define (procedure-backward r)
  (define reasons (hash-ref r 'reason '()))
  (let* ([r (rename-choice r "occurrence" "performed")]
         [r (match (hash-ref r 'outcome #f) [(list (hash-table ('concept c))) (hash-set r 'outcome c)] [_ r])]
         [r (hash-remove r 'reason)]
         [r (set-or-drop r 'reasonCode (for*/list ([x reasons] [c (in-value (hash-ref x 'concept #f))] #:when c) c))]
         [r (set-or-drop r 'reasonReference (for*/list ([x reasons] [c (in-value (hash-ref x 'reference #f))] #:when c) c))])
    r))

;; ---- MedicationDispense, Medication --------------------------------------------------------------

(define (dispense-forward r)
  (let* ([r (cond [(hash-ref r 'medicationCodeableConcept #f)
                   => (lambda (c) (hash-set (hash-remove r 'medicationCodeableConcept) 'medication (hasheq 'concept c)))]
                  [(hash-ref r 'medicationReference #f)
                   => (lambda (x) (hash-set (hash-remove r 'medicationReference) 'medication (hasheq 'reference x)))]
                  [else r])]
         [r (if (equal? (hash-ref r 'status #f) "stopped") (hash-set r 'status "unfulfilled") r)])
    r))

(define (dispense-backward r)
  (let* ([m (hash-ref r 'medication #f)]
         [r (cond [(and (hash? m) (hash-ref m 'concept #f)) => (lambda (c) (hash-set (hash-remove r 'medication) 'medicationCodeableConcept c))]
                  [(and (hash? m) (hash-ref m 'reference #f)) => (lambda (x) (hash-set (hash-remove r 'medication) 'medicationReference x))]
                  [else r])]
         [r (if (equal? (hash-ref r 'status #f) "unfulfilled") (hash-set r 'status "stopped") r)])
    r))

(define (medication-forward r)
  (if (hash-has-key? r 'amount)
      (hash-set (hash-remove r 'amount) 'packageSize (hasheq 'amountPerItem (hash-ref r 'amount)))
      r))
(define (medication-backward r)
  (match (hash-ref r 'packageSize #f)
    [(hash-table ('amountPerItem a)) (hash-set (hash-remove r 'packageSize) 'amount a)]
    [_ r]))

;; ---- Claim, ExplanationOfBenefit ---------------------------------------------------------------

(define (patient->subject r) (rename r 'patient 'subject))
(define (subject->patient r) (rename r 'subject 'patient))

;; ---- registry ----------------------------------------------------------------------------------

(define rules
  (for/hash ([r (list (rule "Encounter" encounter-forward encounter-backward)
                      (rule "Procedure" procedure-forward procedure-backward)
                      (rule "MedicationDispense" dispense-forward dispense-backward)
                      (rule "Medication" medication-forward medication-backward)
                      (rule "Claim" patient->subject subject->patient)
                      (rule "ExplanationOfBenefit" patient->subject subject->patient))])
    (values (rule-type r) r)))

(define converted-types (sort (hash-keys rules) string<?))

;; r4->r6 / r6->r4 : Resource -> Resource   Bundles convert entry by entry
(define (r4->r6 r) (convert r rule-forward))
(define (r6->r4 r) (convert r rule-backward))
(define (convert r which)
  (match (hash-ref r 'resourceType #f)
    ["Bundle" (update-each r 'entry (lambda (e) (if (hash? (hash-ref e 'resource #f)) (hash-set e 'resource (convert (hash-ref e 'resource) which)) e)))]
    [t (let ([ru (hash-ref rules t #f)]) (if ru ((which ru) r) r))]))

(module+ test
  (require rackunit)
  (define enc (hasheq 'resourceType "Encounter" 'id "e1" 'status "finished"
                      'class (hasheq 'system "http://terminology.hl7.org/CodeSystem/v3-ActCode" 'code "AMB")
                      'period (hasheq 'start "2025-03-01" 'end "2025-03-01")
                      'diagnosis (list (hasheq 'condition (hasheq 'reference "Condition/c1") 'rank 1))
                      'participant (list (hasheq 'individual (hasheq 'reference "Practitioner/p1")))))
  (define enc6 (r4->r6 enc))
  (check-equal? (hash-ref enc6 'status) "completed")
  (check-equal? (hash-ref enc6 'class) (list (hasheq 'coding (list (hash-ref enc 'class)))))
  (check-equal? (hash-ref enc6 'actualPeriod) (hash-ref enc 'period))
  (check-equal? (hash-ref (car (hash-ref enc6 'diagnosis)) 'condition) (list (hasheq 'reference (hasheq 'reference "Condition/c1"))))
  (check-equal? (hash-ref (car (hash-ref enc6 'participant)) 'actor) (hasheq 'reference "Practitioner/p1"))
  (check-equal? (r6->r4 enc6) enc)
  ;; a lossy status keeps its R4 code
  (define arrived (hash-set enc 'status "arrived"))
  (check-equal? (hash-ref (r4->r6 arrived) 'status) "in-progress")
  (check-equal? (r6->r4 (r4->r6 arrived)) arrived)
  (define proc (hasheq 'resourceType "Procedure" 'id "p" 'status "completed"
                       'performedPeriod (hasheq 'start "2025-03-03")
                       'outcome (hasheq 'text "ok")
                       'reasonCode (list (hasheq 'text "r")) 'reasonReference (list (hasheq 'reference "Condition/c"))))
  (define proc6 (r4->r6 proc))
  (check-equal? (hash-ref proc6 'occurrencePeriod) (hasheq 'start "2025-03-03"))
  (check-equal? (hash-ref proc6 'reason) (list (hasheq 'concept (hasheq 'text "r")) (hasheq 'reference (hasheq 'reference "Condition/c"))))
  (check-equal? (r6->r4 proc6) proc)
  (define md (hasheq 'resourceType "MedicationDispense" 'status "stopped" 'medicationCodeableConcept (hasheq 'text "x")))
  (check-equal? (hash-ref (r4->r6 md) 'medication) (hasheq 'concept (hasheq 'text "x")))
  (check-equal? (r6->r4 (r4->r6 md)) md)
  (define med (hasheq 'resourceType "Medication" 'amount (hasheq 'numerator (hasheq 'value 30))))
  (check-equal? (r6->r4 (r4->r6 med)) med)
  (check-equal? (r4->r6 (hasheq 'resourceType "Patient" 'id "x")) (hasheq 'resourceType "Patient" 'id "x")))
