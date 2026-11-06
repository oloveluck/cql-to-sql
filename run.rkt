#lang racket/base

;;; run.rkt — run translated SQL in an in-process SQLite (db-lib), for the oracles and `raco
;;; cql-to-sql run`.
;;;
;;; run-expression translates one ELM expression, runs `SELECT <sql> AS v`, and decodes the value
;;; by the term's CQL type. A runtime SQL error (a deliberate one, such as SingletonFrom over two
;;; elements, or any other) is raised as exn:fail:sql-run with the SQL text.

(require racket/contract
         db
         "translate.rkt"
         "decode.rkt"
         (only-in "sql/ast.rkt" select)
         "sql/print.rkt")

(provide
 (struct-out exn:fail:sql-run)
 (contract-out
  [run-expression (->* (any/c) (#:connection (or/c connection? #f)) any/c)]
  [expression-sql (-> any/c string?)]
  [memory-connection (-> connection?)]))

(struct exn:fail:sql-run exn:fail (sql) #:transparent)

(define (memory-connection) (sqlite3-connect #:database 'memory))

;; expression-sql : ELM -> String   the SELECT that computes it
(define (expression-sql elm)
  (sql->string (select (cons (term-sql (translate elm (make-tenv))) "v"))))

;; run-expression : ELM [#:connection] -> CqlValue   raises exn:fail:untranslatable or exn:fail:sql-run
(define (run-expression elm #:connection [conn #f])
  (define t (translate elm (make-tenv)))
  (define sql (sql->string (select (cons (term-sql t) "v"))))
  (define c (or conn (memory-connection)))
  (define v (with-handlers ([exn:fail:sql? (lambda (e) (raise (exn:fail:sql-run (exn-message e) (current-continuation-marks) sql)))])
              (query-value c sql)))
  (unless conn (disconnect c))
  (decode v (term-type t)))

(module+ test
  (require rackunit
           cql/elm/ast
           (only-in cql/value cql-null?))
  (define (lit t v) (elm-literal t v))
  (check-equal? (run-expression (elm-nary "Add" (list (lit "Integer" "1") (lit "Integer" "2")) "Integer")) 3)
  (check-true (cql-null? (run-expression (elm-nary "Divide" (list (lit "Integer" "1") (lit "Integer" "0")) "Decimal"))))
  (check-equal? (run-expression (elm-list (list (lit "Integer" "3") (lit "Integer" "1")))) '(3 1))
  (check-exn exn:fail:sql-run?
             (lambda () (run-expression (elm-unary "SingletonFrom" (elm-list (list (lit "Integer" "1") (lit "Integer" "2"))) #f)))))
