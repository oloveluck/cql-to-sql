#lang racket/base

;;; repair.rkt — the invalid-FHIR values the interpreter tolerates, made valid before flattening.
;;;
;;; The view engine parses resources against the FHIR model and drops a value that is not valid
;;; there; the CQL interpreter reads the raw JSON and copes. Without a repair the relational model
;;; would silently lack such values (the R4 check, check.rkt, reports them). Two repairs, each
;;; counted:
;;;   - a dateTime with a time but no zone (FHIR requires one), in a dateTime field (…DateTime,
;;;     Period start/end, recordedDate, issued, …), gets `zone-offset`, the way the
;;;     interpreter gives it the evaluation's offset (cql/value's current-evaluation-offset): only
;;;     when an offset is given, since the right one is the evaluation's;
;;;   - "true"/"false" strings in a boolean field (`…Boolean`, preferred, active, doNotPerform)
;;;     become booleans.
;;;
;;; A Repairs is (hash 'zone Natural 'boolean Natural): how many values each repair changed.

(require racket/contract
         racket/match
         racket/string)

(provide
 (contract-out
  [repair-resources (->* ((listof hash?)) (#:zone-offset (or/c #f string?)) (values (listof hash?) hash?))]))

(define zone-less-rx #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?$")
(define boolean-keys '(preferred active doNotPerform))
(define (boolean-key? k) (or (memq k boolean-keys) (string-suffix? (symbol->string k) "Boolean")))
;; dateTime/instant fields: choice forms (…DateTime), Period bounds, and the named ones
(define datetime-keys '(start end recordedDate authoredOn whenHandedOver whenPrepared issued date created lastUpdated))
(define (datetime-key? k) (or (memq k datetime-keys) (string-suffix? (symbol->string k) "DateTime")))

;; repair-resources : (listof Resource) [#:zone-offset] -> (values (listof Resource) Repairs)
(define (repair-resources rs #:zone-offset [zone #f])
  (define counts (make-hasheq '((zone . 0) (boolean . 0))))
  (define (bump k) (hash-update! counts k add1))
  (define (fix-value k v)
    (cond [(and zone (datetime-key? k) (string? v) (regexp-match? zone-less-rx v)) (bump 'zone) (string-append v zone)]
          [(and (boolean-key? k) (member v '("true" "false"))) (bump 'boolean) (equal? v "true")]
          [else (walk v)]))
  (define (walk x)
    (cond [(hash? x) (for/hasheq ([(k v) (in-hash x)]) (values k (if (list? v) (map (lambda (e) (fix-value k e)) v) (fix-value k v))))]
          [(list? x) (map walk x)]
          [else x]))
  (define out (map walk rs))
  (values out (for/hash ([(k v) (in-hash counts)]) (values k v))))

(module+ test
  (require rackunit)
  (define-values (rs n)
    (repair-resources (list (hasheq 'resourceType "Observation" 'effectiveDateTime "2019-01-17T12:30:00" 'valueBoolean "true"
                                    'issued "2019-01-17T12:30:00Z" 'code (hasheq 'text "2019-01-17T12:30")))
                      #:zone-offset "-07:00"))
  (check-equal? (hash-ref (car rs) 'effectiveDateTime) "2019-01-17T12:30:00-07:00")
  (check-equal? (hash-ref (car rs) 'valueBoolean) #t)
  (check-equal? (hash-ref (car rs) 'issued) "2019-01-17T12:30:00Z")
  (check-equal? (hash-ref (hash-ref (car rs) 'code) 'text) "2019-01-17T12:30")   ; free text is not a dateTime
  (check-equal? n (hash 'zone 1 'boolean 1))
  ;; without an offset, dateTimes are left alone
  (define-values (rs2 n2) (repair-resources (list (hasheq 'effectiveDateTime "2019-01-17T12:30:00"))))
  (check-equal? (hash-ref (car rs2) 'effectiveDateTime) "2019-01-17T12:30:00")
  (check-equal? n2 (hash 'zone 0 'boolean 0)))
