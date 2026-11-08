#lang racket/base

;;; evidence.rkt — why the measure placed a member where it did: the records behind each decision.
;;;
;;; NCQA tags the defines that hold the evidence for each population in BCSE_Details:
;;;   /* @supportingEvidence: numerator.evidence */  define "Claims for mammography": …
;;; This reads those tags from the measure's own CQL (the public defines; private ones are not
;;; reachable from outside the library), evaluates each for a member, and renders what it holds:
;;; resources as one line each (type, code, date), other values as text. Empty and false evidence is
;;; left out.
;;;
;;; An Evidence is (hash 'section String 'define String 'items (listof String))
;;;   section: "eligible", "excused" or "screened", from the tag's population

(require racket/contract racket/list racket/string json
         (only-in cql/run rlib-value)
         (only-in cql/value cql-null? cql-null-list? cql-tuple? cql-tuple-fields model-node? model-node-data render)
         "measure.rkt")

(provide
 (contract-out
  [evidence-defines (-> (listof (cons/c string? string?)))]
  [member-evidence (-> any/c (listof (cons/c string? string?)) (listof hash?))]
  [resource-line (-> hash? string?)]))

;; evidence-defines : -> (listof (cons section define-name))   in the order the measure declares them
(define (evidence-defines)
  (define text (library-text "BCSE_Details"))
  (define tagged
    (for/list ([m (regexp-match* #px"@supportingEvidence: ([a-z-]+)[.][^\n]*\n(?:[ \t]*[*][^\n]*\n)*?[ \t]*define \"([^\"]+)\""
                                 text #:match-select cdr)])
      (cons (section-of (car m)) (cadr m))))
  ;; "Reports for mammography" is in the Numerator but not tagged
  (remove-duplicates (append tagged (list (cons "screened" "Reports for mammography")))))

(define (section-of population)
  (case population
    [("initial-population") "eligible"]
    [("denominator-exclusion") "excused"]
    [("numerator") "screened"]
    [else population]))

;; member-evidence : rlib (listof (cons section name)) -> (listof Evidence)
(define (member-evidence rl defines)
  (for*/list ([d defines]
              [items (in-value (with-handlers ([(lambda (_) #t) (lambda (_) '())]) (value-lines (rlib-value rl (cdr d)))))]
              #:unless (null? items))
    (hasheq 'section (car d) 'define (cdr d) 'items items)))

;; value-lines : CQL value -> (listof String)   nothing for null, false and empty
(define (value-lines v)
  (cond [(or (cql-null? v) (cql-null-list? v) (eq? v #f) (null? v)) (quote ())]
        [(eq? v #t) '("yes")]
        [(list? v) (remove-duplicates (append-map value-lines v))]
        [(model-node? v) (let ([js (model-node-data v)])
                          (if (and (hash? js) (hash-ref js 'resourceType #f)) (list (resource-line js)) (list (render v))))]
        [(cql-tuple? v) (append-map value-lines (for/list ([(_k x) (cql-tuple-fields v)]) x))]
        [else (let ([s (render v)]) (if (equal? s "null") (quote ()) (list s)))]))

;; ---- one line per resource --------------------------------------------------------------------
(define (codings cc) (if (hash? cc) (hash-ref cc 'coding '()) '()))

;; the codes a resource is about, by type
(define (resource-codes r)
  (define (cc k) (let ([v (hash-ref r k #f)]) (cond [(list? v) (append-map codings v)] [else (codings v)])))
  (case (hash-ref r 'resourceType)
    [("Claim" "ExplanationOfBenefit")
     (append (for*/list ([it (hash-ref r 'item '())] [c (codings (hash-ref it 'productOrService #f))]) c)
             (for*/list ([d (hash-ref r 'diagnosis '())] [c (codings (hash-ref d 'diagnosisCodeableConcept #f))]) c))]
    [("Coverage") (cc 'type)]
    [("Encounter") (cc 'type)]
    [("MedicationDispense" "MedicationRequest") (cc 'medicationCodeableConcept)]
    [("Patient") '()]
    [else (cc 'code)]))

(define (short-system s)
  (cond [(not (string? s)) ""]
        [(regexp-match? #rx"ama-assn" s) "CPT"]
        [(regexp-match? #rx"icd-10-cm" s) "ICD-10-CM"]
        [(regexp-match? #rx"ICD10|icd-10-pcs" s) "ICD-10-PCS"]
        [(regexp-match? #rx"snomed" s) "SNOMED"]
        [(regexp-match? #rx"loinc" s) "LOINC"]
        [(regexp-match? #rx"HCPCS" s) "HCPCS"]
        [(regexp-match? #rx"hedis-coverage-type" s) "HEDIS coverage"]
        [(regexp-match? #rx"sopt" s) "SOPT"]
        [else (last (string-split s "/"))]))

(define (coding-text c)
  (string-append (short-system (hash-ref c 'system #f)) " " (hash-ref c 'code "?")
                 (let ([d (hash-ref c 'display #f)]) (if d (format " (~a)" d) ""))))

;; the date a resource is about
(define (resource-date r)
  (define (start p) (and (hash? p) (or (hash-ref p 'start #f) (hash-ref p 'end #f))))
  (define (range p) (and (hash? p) (format "~a to ~a" (hash-ref p 'start "?") (hash-ref p 'end "open"))))
  (define d
    (case (hash-ref r 'resourceType)
      [("Coverage") (range (hash-ref r 'period #f))]
      [("Claim" "ExplanationOfBenefit")
       (or (for/first ([it (hash-ref r 'item '())] #:when (hash-ref it 'servicedDate #f)) (hash-ref it 'servicedDate))
           (start (hash-ref r 'billablePeriod #f)))]
      [("Patient") (let ([dd (hash-ref r 'deceasedDateTime #f)]) (and dd (string-append "died " dd)))]
      [else (or (hash-ref r 'performedDateTime #f) (start (hash-ref r 'performedPeriod #f))
                (hash-ref r 'effectiveDateTime #f) (start (hash-ref r 'effectivePeriod #f))
                (hash-ref r 'onsetDateTime #f) (hash-ref r 'recordedDate #f)
                (start (hash-ref r 'period #f)) (hash-ref r 'authoredOn #f) (hash-ref r 'whenHandedOver #f))]))
  (and (string? d) (if (regexp-match? #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T" d) (substring d 0 10) d)))

;; resource-line : resource -> String   e.g. "Claim 9f2c…: CPT 77067 (Screening mammography), 2025-03-10"
(define (resource-line r)
  (define codes (remove-duplicates (map coding-text (resource-codes r))))
  (define date (resource-date r))
  (define status (hash-ref r 'status #f))
  (string-append (hash-ref r 'resourceType) " " (let ([id (hash-ref r 'id "")]) (if (> (string-length id) 8) (string-append (substring id 0 8) "…") id))
                 (if (null? codes) "" (string-append ": " (string-join (take codes (min 3 (length codes))) "; ")))
                 (if date (string-append ", " date) "")
                 (if (and (string? status) (not (member status '("active" "completed" "final" "finished")))) (format " [~a]" status) "")))

(module+ test
  (require rackunit)
  (check-equal? (resource-line (hasheq 'resourceType "Procedure" 'id "p1" 'status "completed" 'performedDateTime "2025-04-24T09:00:00-05:00"
                                       'code (hasheq 'coding (list (hasheq 'system "http://www.ama-assn.org/go/cpt" 'code "77067" 'display "Screening mammography")))))
                "Procedure p1: CPT 77067 (Screening mammography), 2025-04-24")
  (check-equal? (resource-line (hasheq 'resourceType "Coverage" 'id "c1" 'status "cancelled" 'period (hasheq 'start "2022-01-01")
                                       'type (hasheq 'coding (list (hasheq 'system "https://nahdo.org/sopt" 'code "2")))))
                "Coverage c1: SOPT 2, 2022-01-01 to open [cancelled]")
  (check-equal? (section-of "denominator-exclusion") "excused"))
