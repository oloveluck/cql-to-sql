#lang racket/base

;;; ast.rkt — the SQL the translator builds, as data. sql/print.rkt writes it out for a dialect.
;;;
;;; A SqlExpr is one of:
;;; - (sql-lit v)               v: exact integer | real | string | #t | #f | 'null
;;; - (sql-param name)          a named query parameter (:name in SQL-on-FHIR's SQLQuery)
;;; - (sql-ref qualifier name)  a column; qualifier a table alias or #f
;;; - (sql-bin op a b)          infix: "+" "-" "*" "/" "%" "||" "=" "<>" "<" "<=" ">" ">=" "AND" "OR"
;;;                             "IS" "IS NOT" (null-safe comparison)
;;; - (sql-un op a)             prefix: "NOT" "-"
;;; - (sql-call name args)      a function call, written as named
;;; - (sql-case clauses else)   searched CASE; clauses (listof (cons when then)); else SqlExpr|#f
;;; - (sql-null-test a negated?) a IS NULL / a IS NOT NULL
;;; - (sql-cast a type)         CAST(a AS type)
;;; - (sql-exists select)       EXISTS (select)
;;; - (sql-scalar select)       (select) as a value
;;; - (sql-in a select)         a IN (select)
;;;
;;; A SqlSelect is (sql-select distinct? items from where group-by order-by limit offset):
;;;   items    : (listof (cons SqlExpr (or String #f)))   expression AS alias
;;;   from     : (listof FromItem)                         comma-joined (cross product)
;;;   where    : SqlExpr | #f
;;;   group-by : (listof SqlExpr)
;;;   order-by : (listof (cons SqlExpr (or 'asc 'desc)))
;;;   limit, offset : SqlExpr | #f
;;; A FromItem is one of:
;;; - (sql-table name alias)          a table or CTE
;;; - (sql-subquery select alias)     (select) AS alias
;;; - (sql-table-fn call alias)       a table-valued function: json_each(x) AS alias
;;; A SqlQuery is a SqlSelect, (sql-union-all queries), or (sql-with ctes body):
;;;   ctes : (listof (cons String SqlQuery)) ; body : SqlQuery

(provide (struct-out sql-lit) (struct-out sql-param) (struct-out sql-ref) (struct-out sql-bin)
         (struct-out sql-un) (struct-out sql-call) (struct-out sql-case) (struct-out sql-null-test)
         (struct-out sql-cast) (struct-out sql-exists) (struct-out sql-scalar) (struct-out sql-in)
         (struct-out sql-select) (struct-out sql-table) (struct-out sql-subquery) (struct-out sql-table-fn)
         (struct-out sql-union-all) (struct-out sql-with)
         select sql-null sql-true sql-false sql-and sql-or)

(struct sql-lit (v) #:prefab)
(struct sql-param (name) #:prefab)
(struct sql-ref (qualifier name) #:prefab)
(struct sql-bin (op a b) #:prefab)
(struct sql-un (op a) #:prefab)
(struct sql-call (name args) #:prefab)
(struct sql-case (clauses else) #:prefab)
(struct sql-null-test (a negated?) #:prefab)
(struct sql-cast (a type) #:prefab)
(struct sql-exists (select) #:prefab)
(struct sql-scalar (select) #:prefab)
(struct sql-in (a select) #:prefab)

(struct sql-select (distinct? items from where group-by order-by limit offset) #:prefab)
(struct sql-table (name alias) #:prefab)
(struct sql-subquery (select alias) #:prefab)
(struct sql-table-fn (call alias) #:prefab)
(struct sql-union-all (queries) #:prefab)
(struct sql-with (ctes body) #:prefab)

(define sql-null (sql-lit 'null))
(define sql-true (sql-lit #t))
(define sql-false (sql-lit #f))

;; select : SqlExpr ... keyword options -> SqlSelect   a SELECT with defaults
(define (select #:distinct? [distinct? #f] #:from [from '()] #:where [where #f] #:group-by [group-by '()]
                #:order-by [order-by '()] #:limit [limit #f] #:offset [offset #f] . items)
  (sql-select distinct? (for/list ([i items]) (if (pair? i) i (cons i #f))) from where group-by order-by limit offset))

;; sql-and / sql-or : SqlExpr ... -> SqlExpr   folded, dropping trivially true / false operands
(define (sql-and . xs)
  (define ys (filter (lambda (x) (not (equal? x sql-true))) xs))
  (cond [(null? ys) sql-true] [else (foldl (lambda (x acc) (sql-bin "AND" acc x)) (car ys) (cdr ys))]))
(define (sql-or . xs)
  (define ys (filter (lambda (x) (not (equal? x sql-false))) xs))
  (cond [(null? ys) sql-false] [else (foldl (lambda (x acc) (sql-bin "OR" acc x)) (car ys) (cdr ys))]))

(module+ test
  (require rackunit)
  (check-equal? (sql-and sql-true (sql-ref #f "a")) (sql-ref #f "a"))
  (check-equal? (sql-and (sql-ref #f "a") (sql-ref #f "b")) (sql-bin "AND" (sql-ref #f "a") (sql-ref #f "b")))
  (check-equal? (sql-select-items (select (sql-lit 1) (cons (sql-lit 2) "two")))
                (list (cons (sql-lit 1) #f) (cons (sql-lit 2) "two"))))
