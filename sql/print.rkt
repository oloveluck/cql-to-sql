#lang racket/base

;;; print.rkt — SQL text from the AST (sql/ast.rkt) for a dialect.
;;;
;;; The translator already chose dialect-specific functions (sql/dialect.rkt) when it built the
;;; AST; printing differs per dialect only in parameter syntax. Every compound expression is
;;; parenthesised, so precedence never depends on the dialect.

(require racket/contract
         racket/match
         racket/string
         "ast.rkt")

(provide
 (contract-out
  [sql->string (->* (any/c) (#:dialect symbol?) string?)]))

;; sql->string : SqlQuery|SqlExpr [#:dialect] -> String
(define (sql->string x #:dialect [d 'sqlite])
  (define (expr e)
    (match e
      [(sql-lit 'null) "NULL"]
      [(sql-lit #t) "TRUE"]
      [(sql-lit #f) "FALSE"]
      [(sql-lit (? exact-integer? n)) (number->string n)]
      [(sql-lit (? real? r)) (real->sql r)]
      [(sql-lit (? string? s)) (quote-string s)]
      [(sql-param n) (if (eq? d 'duckdb) (string-append "$" n) (string-append ":" n))]
      [(sql-ref #f n) (quote-ident n)]
      [(sql-ref q n) (string-append (quote-ident q) "." (quote-ident n))]
      [(sql-bin op a b) (format "(~a ~a ~a)" (expr a) op (expr b))]
      [(sql-un "-" a) (format "(- ~a)" (expr a))]
      [(sql-un op a) (format "(~a ~a)" op (expr a))]
      [(sql-call name args) (format "~a(~a)" name (string-join (map expr args) ", "))]
      [(sql-case clauses els)
       (string-append "CASE"
                      (apply string-append (for/list ([c clauses]) (format " WHEN ~a THEN ~a" (expr (car c)) (expr (cdr c)))))
                      (if els (format " ELSE ~a" (expr els)) "")
                      " END")]
      [(sql-null-test a neg?) (format "(~a IS ~aNULL)" (expr a) (if neg? "NOT " ""))]
      [(sql-cast a t) (format "CAST(~a AS ~a)" (expr a) t)]
      [(sql-exists s) (format "EXISTS (~a)" (query s))]
      [(sql-scalar s) (format "(~a)" (query s))]
      [(sql-in a s) (format "(~a IN (~a))" (expr a) (query s))]
      [_ (query e)]))
  (define (from-item f)
    (match f
      [(sql-table n a) (if (and a (not (equal? a n))) (format "~a AS ~a" (quote-ident n) (quote-ident a)) (quote-ident n))]
      [(sql-subquery s a) (format "(~a) AS ~a" (query s) (quote-ident a))]
      [(sql-table-fn c a) (format "~a AS ~a" (expr c) (quote-ident a))]))
  (define (query q)
    (match q
      [(sql-select distinct? items from where group order limit offset)
       (string-append
        "SELECT " (if distinct? "DISTINCT " "")
        (string-join (for/list ([i items]) (if (cdr i) (format "~a AS ~a" (expr (car i)) (quote-ident (cdr i))) (expr (car i)))) ", ")
        (if (null? from) "" (string-append " FROM " (string-join (map from-item from) ", ")))
        (if where (string-append " WHERE " (expr where)) "")
        (if (null? group) "" (string-append " GROUP BY " (string-join (map expr group) ", ")))
        (if (null? order) ""
            (string-append " ORDER BY " (string-join (for/list ([o order]) (format "~a ~a" (expr (car o)) (if (eq? (cdr o) 'desc) "DESC" "ASC"))) ", ")))
        (if limit (string-append " LIMIT " (expr limit)) "")
        (if offset (string-append " OFFSET " (expr offset)) ""))]
      [(sql-union-all qs) (string-join (for/list ([s qs]) (format "SELECT * FROM (~a)" (query s))) " UNION ALL ")]
      [(sql-with ctes body)
       (string-append "WITH "
                      (string-join (for/list ([c ctes]) (format "~a AS (~a)" (quote-ident (car c)) (query (cdr c)))) ", ")
                      " " (query body))]
      [_ (raise-argument-error 'sql->string "a SQL query or expression" q)]))
  (expr x))

;; quote-ident : String -> String   bare when it is a plain identifier, else "double quoted"
(define (quote-ident s)
  (if (and (regexp-match? #px"^[A-Za-z_][A-Za-z0-9_]*$" s) (not (member (string-upcase s) reserved)))
      s
      (string-append "\"" (regexp-replace* #rx"\"" s "\"\"") "\"")))

(define reserved '("SELECT" "FROM" "WHERE" "GROUP" "ORDER" "BY" "AS" "AND" "OR" "NOT" "NULL" "VALUE" "KEY"
                   "TABLE" "CASE" "WHEN" "THEN" "ELSE" "END" "IN" "IS" "EXISTS" "LIMIT" "OFFSET" "WITH" "UNION" "ALL"))

(define (quote-string s) (string-append "'" (regexp-replace* #rx"'" s "''") "'"))

;; real->sql : Real -> String   never in exponent notation or as an integer (1.0, not 1)
(define (real->sql r)
  (define s (number->string (exact->inexact r)))
  (cond [(regexp-match? #rx"[eE]" s) (number->string (exact->inexact r))]
        [(regexp-match? #rx"[.]" s) s]
        [else (string-append s ".0")]))

(module+ test
  (require rackunit)
  (check-equal? (sql->string (sql-bin "+" (sql-lit 1) (sql-lit 2))) "(1 + 2)")
  (check-equal? (sql->string (sql-lit "it's")) "'it''s'")
  (check-equal? (sql->string (sql-param "start")) ":start")
  (check-equal? (sql->string (sql-param "start") #:dialect 'duckdb) "$start")
  (check-equal? (sql->string (sql-ref "t" "value")) "t.\"value\"")
  (check-equal? (sql->string (select (sql-call "count" (list (sql-ref "j" "value")))
                                     #:from (list (sql-table-fn (sql-call "json_each" (list (sql-lit "[1]"))) "j"))
                                     #:where (sql-null-test (sql-ref "j" "value") #t)))
                "SELECT count(j.\"value\") FROM json_each('[1]') AS j WHERE (j.\"value\" IS NOT NULL)")
  (check-equal? (sql->string (sql-with (list (cons "d" (select (cons (sql-lit 1) "x")))) (select (sql-ref #f "x") #:from (list (sql-table "d" #f)))))
                "WITH d AS (SELECT 1 AS x) SELECT x FROM d")
  (check-equal? (sql->string (sql-case (list (cons sql-true (sql-lit 1))) sql-null)) "CASE WHEN TRUE THEN 1 ELSE NULL END")
  (check-equal? (sql->string (sql-lit 2.5)) "2.5")
  (check-equal? (sql->string (sql-lit 2.0)) "2.0"))
