#lang racket/base

;;; check.rkt — the relational model loses nothing the measure reads (PLAN.md R4).
;;;
;;; Two independent checks over the same resources:
;;; 1. The conversion is lossless: r6->r4 (r4->r6 r) = r for every resource.
;;; 2. The flattening is complete: for every table column, the rows a small path walker computes
;;;    from the converted JSON (not sql-on-fhir's engine) equal the rows in the table, as a
;;;    multiset of (resource key, element positions…, value).
;;; A column whose path uses a function the walker does not know is reported as skipped, so the
;;; coverage of the check is explicit.
;;;
;;; A ColumnResult is (column-result table column status detail):
;;;   status : 'ok | 'mismatch | 'skipped
;;;   detail : #f, or a string (the first differing rows, or why skipped)

(require racket/contract
         racket/list
         racket/match
         racket/string
         json
         (only-in db query-rows sql-null? connection?)
         "r4-to-r6.rkt"
         "repair.rkt"
         "spec.rkt")

(provide
 (struct-out column-result)
 (contract-out
  [round-trip-failures (-> (listof hash?) (listof hash?))]
  [check-tables (->* ((listof hash?) connection?) (#:zone-offset (or/c #f string?)) (listof column-result?))]))

(struct column-result (table column status detail) #:transparent)

;; round-trip-failures : (listof R4 Resource) -> (listof Resource)   those the conversion does not invert
(define (round-trip-failures rs)
  (filter (lambda (r) (not (equal? (r6->r4 (r4->r6 r)) r))) rs))

;; ---- the path walker -----------------------------------------------------------------------------
;; A Seg is one of: (list 'field Symbol) | (list 'first) | (list 'this) | (list 'resource-key)
;;   | (list 'ref-key String) | (list 'ext String) | (list 'row-index)
;; parse-path : String -> (listof Seg) | #f   #f: a function the walker does not know

(define (split-dots s)
  (let loop ([cs (string->list s)] [depth 0] [cur '()] [out '()])
    (cond [(null? cs) (reverse (cons (list->string (reverse cur)) out))]
          [(and (char=? (car cs) #\.) (zero? depth)) (loop (cdr cs) depth '() (cons (list->string (reverse cur)) out))]
          [else (loop (cdr cs) (case (car cs) [(#\() (add1 depth)] [(#\)) (sub1 depth)] [else depth]) (cons (car cs) cur) out)])))

(define (parse-path s)
  (let loop ([parts (split-dots s)] [acc '()])
    (match parts
      ['() (reverse acc)]
      [(list* (? (lambda (p) (regexp-match? #px"^[A-Za-z]+$" p)) f) (pregexp #px"^ofType\\(([A-Za-z]+)\\)$" (list _ t)) more)
       (loop more (cons (list 'field (string->symbol (string-append f (string-upcase (substring t 0 1)) (substring t 1)))) acc))]
      [(cons "first()" more) (loop more (cons '(first) acc))]
      [(cons "$this" more) (loop more (cons '(this) acc))]
      [(cons "%rowIndex" more) (loop more (cons '(row-index) acc))]
      [(cons "getResourceKey()" more) (loop more (cons '(resource-key) acc))]
      [(cons (pregexp #px"^getReferenceKey\\(([A-Za-z]+)\\)$" (list _ t)) more) (loop more (cons (list 'ref-key t) acc))]
      [(cons (pregexp #px"^extension\\('([^']+)'\\)$" (list _ u)) more) (loop more (cons (list 'ext u) acc))]
      [(cons (? (lambda (p) (regexp-match? #px"^[A-Za-z]+$" p)) f) more) (loop more (cons (list 'field (string->symbol f)) acc))]
      [_ #f])))

;; walk : (listof Seg) jsexpr -> (listof jsexpr)   FHIRPath-style: collections flatten
(define (walk segs x)
  (for/fold ([xs (list x)]) ([seg segs])
    (match seg
      [(list 'field k) (append* (for/list ([v xs] #:when (hash? v))
                                  (define y (hash-ref v k 'absent))
                                  (cond [(eq? y 'absent) '()] [(list? y) y] [else (list y)])))]
      [(list 'first) (if (null? xs) '() (list (car xs)))]
      [(list 'this) xs]
      [(list 'resource-key) (for*/list ([v xs] #:when (hash? v) [id (in-value (hash-ref v 'id #f))] #:when id) id)]
      [(list 'ref-key t)
       (for*/list ([v xs] #:when (hash? v)
                   [m (in-value (regexp-match (pregexp (string-append "(?:^|/)" t "/([^/]+)$")) (hash-ref v 'reference "")))] #:when m)
         (cadr m))]
      [(list 'ext u) (for*/list ([v xs] #:when (hash? v) [e (hash-ref v 'extension '())] #:when (equal? (hash-ref e 'url #f) u)) e)])))

;; ---- expected rows ---------------------------------------------------------------------------------

;; normalize : jsexpr|SQL value -> String   one comparable form for both sides
(define (normalize v)
  (cond [(or (eq? v 'null) (sql-null? v)) "∅"]
        [(eq? v #t) "1"] [(eq? v #f) "0"]
        [(and (real? v) (integer? v)) (number->string (inexact->exact v))]
        [(real? v) (number->string (exact->inexact v))]
        [else (format "~a" v)]))

;; expected-rows : Table Col (listof Resource) -> (listof String) | #f   #f: the path is not walkable
(define (expected-rows t cl rs)
  (define segs (parse-path (col-path cl)))
  (define level-segs (map parse-path (table-levels t)))
  (and segs (andmap values level-segs)
       (for*/list ([r rs] #:when (equal? (hash-ref r 'resourceType #f) (table-resource t))
                   [row (let loop ([elem r] [levels level-segs] [idxs '()])
                          (if (null? levels)
                              (list (cons (reverse idxs) elem))
                              (for/fold ([acc '()]) ([e (walk (car levels) elem)] [i (in-naturals)])
                                (append acc (loop e (cdr levels) (cons i idxs))))))])
         (define vals (walk segs (cdr row)))
         (string-join (append (list (hash-ref r 'id "∅")) (map number->string (car row))
                              (list (if (null? vals) "∅" (string-join (map normalize vals) "|"))))
                      "\t"))))

;; check-tables : (listof R4 Resource) Connection [#:zone-offset] -> (listof ColumnResult)   the
;; connection holds the model built from the same resources with the same repairs
(define (check-tables rs0 conn #:zone-offset [zone #f])
  (define-values (rs _repairs) (repair-resources rs0 #:zone-offset zone))
  (define r6 (map r4->r6 rs))
  (for*/list ([t model] [cl (table-cols t)])
    (define exp (expected-rows t cl r6))
    (cond
      [(not exp) (column-result (table-name t) (col-name cl) 'skipped (format "path not walked: ~a" (col-path cl)))]
      [else
       (define cols (table-columns t))
       (define idx-cols (filter (lambda (c) (regexp-match? #rx"_idx$" c)) cols))
       (define got (for/list ([row (query-rows conn (format "SELECT ~a FROM ~a" (string-join (append (list (car cols)) idx-cols (list (col-name cl))) ", ") (table-name t)))])
                     (string-join (map normalize (vector->list row)) "\t")))
       (define e (sort exp string<?)) (define g (sort got string<?))
       (if (equal? e g)
           (column-result (table-name t) (col-name cl) 'ok #f)
           (column-result (table-name t) (col-name cl) 'mismatch
                          (format "expected ~a rows, table ~a; first only-expected ~s, first only-table ~s"
                                  (length e) (length g) (take-at-most (remove* g e) 2) (take-at-most (remove* e g) 2))))])))

(define (take-at-most l n) (take l (min n (length l))))

(module+ test
  (require rackunit)
  (check-equal? (parse-path "serviced.ofType(Period).start") '((field servicedPeriod) (field start)))
  (check-equal? (parse-path "subject.getReferenceKey(Patient)") '((field subject) (ref-key "Patient")))
  (check-false (parse-path "meta.tag.where(system = 'x').code"))
  (check-equal? (walk (parse-path "coding.code") (hasheq 'coding (list (hasheq 'code "a") (hasheq 'code "b")))) '("a" "b"))
  (check-equal? (walk (parse-path "subject.getReferenceKey(Patient)") (hasheq 'subject (hasheq 'reference "Patient/p1"))) '("p1"))
  (check-equal? (walk (parse-path "extension('u').value.ofType(code)") (hasheq 'extension (list (hasheq 'url "u" 'valueCode "x")))) '("x")))
