#lang racket/base

;;; decode.rkt — a SQL result back as a CQL value (cql/value), by the CQL type the translator gave it.
;;;
;;; The inverse of the encodings in types.rkt: SQL NULL is CQL null; native scalars map directly
;;; (Boolean from 0/1, Decimal from REAL rounded to CQL's 8 decimal places, temporal values from
;;; their ISO lexemes); JSON text is parsed and decoded member by member. Used by the oracles to
;;; compare SQL results with the interpreter's.

(require racket/contract
         racket/match
         json
         (only-in db sql-null?)
         (only-in fhirpath/decimal parse-decimal)
         (only-in fhirpath/value fp-long fp-quantity)
         (only-in fhirpath/temporal-ops parse-fp-date parse-fp-datetime parse-fp-time)
         (only-in cql/value cql-null cql-interval cql-tuple cql-code cql-concept)
         "types.rkt")

(provide
 (contract-out
  [decode (-> any/c cql-type/c any/c)]))

;; decode : SqlValue CqlType -> CqlValue
(define (decode v t)
  (cond
    [(or (sql-null? v) (eq? v 'null)) cql-null]
    [(eq? (type-encoding t) 'json)
     (decode-json (if (string? v) (with-handlers ([exn:fail? (lambda (_) v)]) (string->jsexpr v)) v) t)]
    [else (decode-scalar v t)]))

;; decode-scalar : Native CqlType -> CqlValue
(define (decode-scalar v t)
  (match t
    ['Boolean (match v [(or 1 #t "true") #t] [(or 0 #f "false") #f] [_ cql-null])]
    ['Integer (if (real? v) (inexact->exact (truncate v)) cql-null)]
    ['Long (if (real? v) (fp-long (inexact->exact (truncate v))) cql-null)]
    ['Decimal (if (real? v) (real->decimal v) cql-null)]
    ['String (if (string? v) v (format "~a" v))]
    ['Date (or (and (string? v) (parse-fp-date v)) cql-null)]
    ['DateTime (or (and (string? v) (parse-fp-datetime v)) cql-null)]
    ['Time (or (and (string? v) (parse-fp-time v)) cql-null)]
    [_ (cond [(and (exact-integer? v)) v]
             [(real? v) (real->decimal v)]
             [else v])]))

;; real->decimal : Real -> fp-decimal   rounded to 8 decimal places, trailing zeros dropped
(define (real->decimal r)
  (define x (/ (round (* (inexact->exact r) 100000000)) 100000000))
  (define sign (if (negative? x) "-" ""))
  (define ax (abs x))
  (define ip (floor ax))
  (define frac (- ax ip))
  (define digits (let loop ([f frac] [n 0] [acc ""])
                   (if (or (zero? f) (= n 8)) acc
                       (let* ([d (floor (* f 10))]) (loop (- (* f 10) d) (add1 n) (string-append acc (number->string d)))))))
  (parse-decimal (string-append sign (number->string ip) (if (equal? digits "") ".0" (string-append "." digits)))))

;; decode-json : JSExpr CqlType -> CqlValue
(define (decode-json j t)
  (match* (j t)
    [('null _) cql-null]
    [((? list? xs) (list 'List el)) (for/list ([x xs]) (decode-json x el))]
    [((? hash? h) (list 'Tuple fields))
     (cql-tuple (for/hasheq ([f fields]) (values (car f) (decode-json (hash-ref h (car f) 'null) (cdr f)))))]
    [((? hash? h) (list 'Interval p))
     (cql-interval (decode-json (hash-ref h 'low 'null) p) (decode-json (hash-ref h 'high 'null) p)
                   (truthy (hash-ref h 'lowClosed #t)) (truthy (hash-ref h 'highClosed #t)))]
    [((? hash? h) 'Quantity)
     (define v (hash-ref h 'value 'null))
     (if (real? v) (fp-quantity (or (parse-decimal (number->string v)) (real->decimal v)) (hash-ref h 'unit "1") #f) cql-null)]
    [((? hash? h) 'Code)
     (cql-code (hash-ref h 'code #f) (hash-ref h 'system #f) (hash-ref h 'version #f) (hash-ref h 'display #f))]
    [((? hash? h) 'Concept)
     (cql-concept (for/list ([c (hash-ref h 'codes '())]) (decode-json c 'Code)) (hash-ref h 'display #f))]
    [((? string? s) (? (lambda (t) (eq? (type-encoding t) 'json)))) (decode-json (string->jsexpr s) t)]
    [(_ _) (decode-scalar j t)]))

(define (truthy x) (match x [(or #t 1) #t] [_ #f]))

(module+ test
  (require rackunit
           (only-in fhirpath/decimal decimal->string)
           (only-in cql/value cql-null?))
  (check-true (cql-null? (decode (if #f #f 'null) 'Integer)))
  (check-equal? (decode 1 'Boolean) #t)
  (check-equal? (decode 3 'Integer) 3)
  (check-equal? (decimal->string (decode 0.3333333333333333 'Decimal)) "0.33333333")
  (check-equal? (decimal->string (decode 2.0 'Decimal)) "2.0")
  (check-equal? (decimal->string (decode -1.5 'Decimal)) "-1.5")
  (check-equal? (decode "[1,2,null]" '(List Integer)) (list 1 2 cql-null))
  (check-equal? (decode "[true,0]" '(List Boolean)) (list #t #f))
  (check-equal? (decode "{\"a\":1}" '(Tuple ((a . Integer)))) (cql-tuple (hasheq 'a 1)))
  (check-equal? (decode "{\"low\":1,\"high\":5,\"lowClosed\":true,\"highClosed\":false}" '(Interval Integer))
                (cql-interval 1 5 #t #f))
  (check-equal? (decode "2012-01-05" 'Date) (parse-fp-date "2012-01-05")))
