#lang racket/base

;;; requirements.rkt — what a measure reads, from its ELM: the contract of the relational model
;;; (PLAN.md R1).
;;;
;;;   racket model/requirements.rkt <measure bundle.json> …
;;;
;;; Walks the ELM JSON of every Library in the bundles (application/elm+json) and collects each
;;; FHIR element a Property reads, typed by the ELM's result types: a query alias has its source's
;;; element type, a function operand its declared type. Each element gets its R4 cardinality and
;;; types from the R4 core package, since cardinality decides column vs. child table (R2). Then
;;; `uncovered` lists the resource elements read that no table of the model (spec.rkt) reads.
;;;
;;; A Requirement is (requirement owner element max types):
;;;   owner   : String   the FHIR type read from: "Claim", "Claim.Item", "CodeableConcept"
;;;   element : String   the element's R4 path in the core package: "Claim.item", "Patient.deceased[x]"
;;;   max     : String   "1" or "*" (#f when the core package has no such element)
;;;   types   : (listof String)

(require racket/contract
         racket/list
         racket/match
         racket/set
         racket/string
         json
         net/base64
         (only-in fhir/package read-package)
         (only-in fhir/spec-package spec-package-path)
         "spec.rkt")

(provide
 (struct-out requirement)
 (contract-out
  [measure-elm (-> (listof path-string?) (listof hash?))]
  [elm-reads (-> (listof hash?) (listof (cons/c string? string?)))]
  [requirements (-> (listof hash?) (listof requirement?))]
  [uncovered (-> (listof requirement?) (listof requirement?))]))

(struct requirement (owner element max types) #:transparent)

(define fhir-ns "{http://hl7.org/fhir}")

;; measure-elm : (listof Path) -> (listof ELM jsexpr)   the ELM of every Library in the bundles but
;; FHIRHelpers (its conversions read every FHIR primitive's value, which says nothing about the measure)
(define (measure-elm paths)
  (for*/list ([p paths]
              [e (hash-ref (call-with-input-file p read-json) 'entry '())]
              [r (in-value (hash-ref e 'resource (hasheq)))]
              #:when (equal? (hash-ref r 'resourceType #f) "Library")
              #:unless (equal? (hash-ref r 'name #f) "FHIRHelpers")
              [c (hash-ref r 'content '())]
              #:when (equal? (hash-ref c 'contentType #f) "application/elm+json"))
    (string->jsexpr (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref c 'data)))))))

;; type-name : ELM node -> String|#f   a node's (element) type: resultTypeName, else the named type
;; inside its resultTypeSpecifier (through List/Interval element types)
(define (type-name n)
  (and (hash? n)
       (or (hash-ref n 'resultTypeName #f)
           (let loop ([s (hash-ref n 'resultTypeSpecifier #f)])
             (match s
               [(hash-table ('type "NamedTypeSpecifier") ('name nm)) nm]
               [(hash-table ('elementType et)) (loop et)]
               [_ #f])))))
(define (spec-type-name s)
  (match s
    [(hash-table ('type "NamedTypeSpecifier") ('name nm)) nm]
    [(hash-table ('elementType et)) (spec-type-name et)]
    [_ #f]))

;; elm-reads : (listof ELM) -> (listof (cons Owner Element-name))   every FHIR property read, typed
(define (elm-reads elms)
  (define out (mutable-set))
  (define (fhir t) (and (string? t) (string-prefix? t fhir-ns) (substring t (string-length fhir-ns))))
  (define (walk x scope)
    (cond
      [(hash? x)
       (match (hash-ref x 'type #f)
         ["FunctionDef"
          (define sc (for/fold ([sc scope]) ([o (hash-ref x 'operand '())])
                       (hash-set sc (cons 'operand (hash-ref o 'name)) (spec-type-name (hash-ref o 'operandTypeSpecifier (hasheq))))))
          (for ([(k v) (in-hash x)]) (walk v sc))]
         ["Query"
          (define sc (for/fold ([sc scope]) ([s (append (hash-ref x 'source '()) (hash-ref x 'relationship '()))])
                       (hash-set sc (cons 'alias (hash-ref s 'alias)) (type-name (hash-ref s 'expression #f)))))
          (for ([(k v) (in-hash x)]) (walk v sc))]
         ["Property"
          (define src (hash-ref x 'source #f))
          (define owner
            (cond [(and (hash? src) (equal? (hash-ref src 'type #f) "OperandRef"))
                   (or (type-name src) (hash-ref scope (cons 'operand (hash-ref src 'name)) #f))]
                  [src (type-name src)]
                  [else (hash-ref scope (cons 'alias (hash-ref x 'scope #f)) #f)]))
          (define o (fhir owner))
          (when o (set-add! out (cons o (hash-ref x 'path))))
          (for ([(k v) (in-hash x)]) (walk v scope))]
         [_ (for ([(k v) (in-hash x)]) (walk v scope))])]
      [(list? x) (for ([v x]) (walk v scope))]))
  (for ([e elms]) (walk e (hash)))
  (sort (set->list out) string<? #:key (lambda (p) (string-append (car p) "." (cdr p)))))

;; ---- the R4 core package: elements, cardinality ----------------------------------------------------

(define r4-elements
  (let ([cache #f])
    (lambda ()
      (or cache
          (let-values ([(_m rs _e) (read-package (spec-package-path "hl7.fhir.r4.core.tgz")
                                                 #:select (lambda (f) (regexp-match? #rx"^StructureDefinition-" f)))])
            (set! cache
                  (for*/hash ([r (map cdr rs)] #:when (hash? (hash-ref r 'snapshot #f))
                              [e (hash-ref (hash-ref r 'snapshot) 'element '())]
                              #:unless (hash-ref e 'sliceName #f))
                    (values (hash-ref e 'path) e)))
            cache)))))

;; owner-path : Owner -> String   "Claim.Item.Adjudication" -> "Claim.item.adjudication"
(define (owner-path o)
  (match (string-split o ".")
    [(cons head more) (string-join (cons head (for/list ([m more]) (string-append (string-downcase (substring m 0 1)) (substring m 1)))) ".")]))

;; requirements : (listof ELM) -> (listof Requirement)
(define (requirements elms)
  (define els (r4-elements))
  (for/list ([rd (elm-reads elms)])
    (define base (string-append (owner-path (car rd)) "." (cdr rd)))
    (define e (or (hash-ref els base #f) (hash-ref els (string-append base "[x]") #f)))
    (requirement (car rd) (if e (hash-ref e 'path) base) (and e (hash-ref e 'max #f))
                 (if e (for/list ([t (hash-ref e 'type '())]) (hash-ref t 'code)) '()))))

;; ---- coverage by the model ---------------------------------------------------------------------------

;; R4 element -> the R6 element the model reads it from (the renames in r4-to-r6.rkt)
(define r4->r6-element
  (hash "Encounter.period" "Encounter.actualPeriod" "Encounter.participant.individual" "Encounter.participant.actor"
        "Encounter.diagnosis.rank" "Encounter.diagnosis.extension" "Procedure.performed[x]" "Procedure.occurrence"
        "Procedure.reasonReference" "Procedure.reason" "Procedure.reasonCode" "Procedure.reason"
        "MedicationDispense.medication[x]" "MedicationDispense.medication" "Medication.amount" "Medication.packageSize"
        "Claim.patient" "Claim.subject" "ExplanationOfBenefit.patient" "ExplanationOfBenefit.subject"))

;; model-elements : -> (set String)   every element path a table reads, R6, e.g. "Claim.item.productOrService"
(define (model-elements)
  (define (clean p)
    (for/list ([seg (string-split (regexp-replace* #px"\\([^)]*\\)" p "") ".")]
               #:unless (member seg '("ofType" "first" "where" "getResourceKey" "getReferenceKey" "%rowIndex" "$this" "")))
      seg))
  (for*/set ([t model]
             [x (cons (col "" "" "") (table-cols t))]
             [prefix (in-value (append* (map clean (table-levels t))))]
             [full (in-value (append prefix (clean (col-path x))))]
             [k (in-range 1 (add1 (length full)))])
    (string-join (cons (table-resource t) (take full k)) ".")))

;; uncovered : (listof Requirement) -> (listof Requirement)   resource elements read that no table reads
(define (uncovered reqs)
  (define els (model-elements))
  (define types (remove-duplicates (map table-resource model)))
  (for/list ([r reqs]
             #:when (member (car (string-split (requirement-element r) ".")) types)
             #:unless (let* ([p (requirement-element r)]
                             [p6 (hash-ref r4->r6-element p (regexp-replace #rx"\\[x\\]$" p ""))])
                        (or (set-member? els p6)
                            (regexp-match? #rx"\\.(id|meta)$" p))))   ; the key column, the data_source column
    r))

(module+ test
  (require rackunit)
  (check-equal? (owner-path "ExplanationOfBenefit.Item.Adjudication") "ExplanationOfBenefit.item.adjudication")
  ;; coverage is not vacuous: an element no table reads is reported, a renamed one is found under its R6 name
  (check-equal? (map requirement-element
                     (uncovered (list (requirement "Claim" "Claim.insurance" "*" '("BackboneElement"))
                                      (requirement "Procedure" "Procedure.performed[x]" "1" '("dateTime"))
                                      (requirement "Encounter.Diagnosis" "Encounter.diagnosis.rank" "1" '("positiveInt"))
                                      (requirement "CodeableConcept" "CodeableConcept.coding" "*" '("Coding")))))
                '("Claim.insurance")))

(module+ main
  (define reqs (requirements (measure-elm (vector->list (current-command-line-arguments)))))
  (printf "~a elements read\n" (length reqs))
  (for ([r reqs]) (printf "  ~a ~a ~a\n" (requirement-element r) (or (requirement-max r) "?") (string-join (requirement-types r) "|")))
  (define u (uncovered reqs))
  (printf "~a not read by any table of the model~a\n" (length u) (if (null? u) "" ":"))
  (for ([r u]) (printf "  ~a\n" (requirement-element r))))
