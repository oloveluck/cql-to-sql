#lang racket/base

;;; dialect.rkt — the SQL that differs between engines, as a table per dialect.
;;;
;;; The translator never writes an engine-specific function by name; it asks the dialect for an
;;; operation (dialect-op d 'json-array args). A Dialect is (dialect name ops): ops is a hasheq
;;; OpName -> (SqlExpr ... -> SqlExpr). Both dialects encode structured CQL values as JSON text
;;; (types.rkt), which SQLite's json1 and DuckDB's json extension both speak; they differ in names,
;;; in what an extracted JSON value is (SQLite: a native scalar; DuckDB: JSON, to be cast), and in
;;; how a runtime error is raised.

(require racket/contract
         "ast.rkt")

(provide
 (struct-out dialect)
 (contract-out
  [dialect-op (-> dialect? symbol? any/c ... any/c)]
  [dialect-supports? (-> dialect? symbol? boolean?)]
  [sqlite dialect?]
  [duckdb dialect?]
  [dialect-named (-> symbol? dialect?)]))

(struct dialect (name ops))

;; dialect-op : Dialect OpName SqlExpr ... -> SqlExpr
(define (dialect-op d op . args)
  (define f (hash-ref (dialect-ops d) op
                      (lambda () (raise-arguments-error 'dialect-op "operation not in this dialect" "dialect" (dialect-name d) "op" op))))
  (apply f args))

(define (dialect-supports? d op) (hash-has-key? (dialect-ops d) op))

(define (call name . args) (sql-call name args))

;; operations shared by both dialects (standard SQL or common function names)
(define common
  (hasheq
   'json-array (lambda args (sql-call "json_array" args))
   'json-object (lambda args (sql-call "json_object" args))
   'json-group-array (lambda (x) (call "json_group_array" x))
   'json-length (lambda (x) (call "json_array_length" x))
   'ln (lambda (x) (call "ln" x))
   'exp (lambda (x) (call "exp" x))
   'power (lambda (a b) (call "power" a b))
   'ceil (lambda (x) (call "ceil" x))
   'floor (lambda (x) (call "floor" x))
   'trunc (lambda (x) (call "trunc" x))
   'abs (lambda (x) (call "abs" x))
   'length (lambda (x) (call "length" x))
   'upper (lambda (x) (call "upper" x))
   'lower (lambda (x) (call "lower" x))
   'string-agg (lambda (x sep) (call "group_concat" x sep))))

(define sqlite
  (dialect
   'sqlite
   (for/fold ([h common])
             ([(k v) (in-hash
                      (hasheq
                       ;; an already-JSON-encoded value placed inside json_array/json_object
                       'json-embed (lambda (x) (call "json" x))
                       'json-each (lambda (x) (call "json_each" x))
                       ;; json_extract yields native scalars, JSON text for arrays/objects
                       'json-extract (lambda (x path) (call "json_extract" x path))
                       'json-text (lambda (x) (call "json" x))           ; canonical JSON text
                       'substr (lambda (s start [len #f]) (if len (call "substr" s start len) (call "substr" s start)))
                       'instr (lambda (s sub) (call "instr" s sub))
                       'to-text (lambda (x) (sql-cast x "TEXT"))
                       'to-integer (lambda (x) (sql-cast x "INTEGER"))
                       'to-real (lambda (x) (sql-cast x "REAL"))
                       'round (lambda (x p) (call "round" x p))
                       'printf (lambda args (sql-call "printf" args))
                       ;; no RAISE outside triggers: malformed JSON is a runtime error with a message
                       'error (lambda (msg) (call "json" (sql-lit (string-append "!" msg))))
                       'julianday (lambda (x) (call "julianday" x))
                       'age-in-years-at
                       (lambda (birth as-of)
                         (sql-bin "-"
                                  (sql-bin "-"
                                           (sql-cast (call "strftime" (sql-lit "%Y") as-of) "INTEGER")
                                           (sql-cast (call "strftime" (sql-lit "%Y") birth) "INTEGER"))
                                  (sql-bin "<"
                                           (call "strftime" (sql-lit "%m-%d") as-of)
                                           (call "strftime" (sql-lit "%m-%d") birth))))))])
     (hash-set h k v))))

(define duckdb
  (dialect
   'duckdb
   (for/fold ([h common])
             ([(k v) (in-hash
                      (hasheq
                       'json-embed (lambda (x) (sql-cast x "JSON"))
                       'json-each (lambda (x) (call "json_each" x))
                       'json-extract (lambda (x path) (call "json_extract_string" x path))
                       'json-text (lambda (x) (sql-cast x "JSON"))
                       'substr (lambda (s start [len #f]) (if len (call "substr" s start len) (call "substr" s start)))
                       'instr (lambda (s sub) (call "instr" s sub))
                       'to-text (lambda (x) (sql-cast x "VARCHAR"))
                       'to-integer (lambda (x) (sql-cast x "BIGINT"))
                       'to-real (lambda (x) (sql-cast x "DOUBLE"))
                       'round (lambda (x p) (call "round" x p))
                       'printf (lambda args (sql-call "printf" args))
                       'error (lambda (msg) (call "error" (sql-lit msg)))
                       'julianday (lambda (x) (call "julian" (sql-cast x "DATE")))
                       'age-in-years-at
                       (lambda (birth as-of)
                         (sql-bin "-"
                                  (sql-bin "-"
                                           (sql-cast (call "date_part" (sql-lit "year") (sql-cast as-of "DATE")) "BIGINT")
                                           (sql-cast (call "date_part" (sql-lit "year") (sql-cast birth "DATE")) "BIGINT"))
                                  (sql-case (list (cons (sql-bin "<"
                                                                 (call "strftime" (sql-cast as-of "DATE") (sql-lit "%m-%d"))
                                                                 (call "strftime" (sql-cast birth "DATE") (sql-lit "%m-%d")))
                                                        (sql-lit 1)))
                                            (sql-lit 0))))))])
     (hash-set h k v))))

(define (dialect-named n)
  (case n [(sqlite) sqlite] [(duckdb) duckdb]
    [else (raise-arguments-error 'dialect-named "unknown dialect" "name" n)]))

(module+ test
  (require rackunit)
  (check-equal? (dialect-op sqlite 'json-embed (sql-ref #f "x")) (sql-call "json" (list (sql-ref #f "x"))))
  (check-equal? (dialect-op duckdb 'json-embed (sql-ref #f "x")) (sql-cast (sql-ref #f "x") "JSON"))
  (check-true (dialect-supports? sqlite 'error))
  (check-false (dialect-supports? sqlite 'regexp)))
