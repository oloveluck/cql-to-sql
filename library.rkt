#lang racket/base

;;; library.rkt — translate a whole CQL Library / Measure into SQL CTEs and queries.
;;;
;;; Takes an ELM Library (cql/elm/ast) and produces a SQL AST (sql/ast) containing a graph of
;;; Common Table Expressions (one per define) and a final population SELECT query returning one
;;; row per patient, keyed by patient_id.

(require racket/contract
         racket/list
         racket/match
         racket/string
         racket/set
         cql/elm/ast
         (only-in cql/parser/parse parse-cql)
         (only-in cql/compile compile-library)
         (only-in fhir/result/result ok? ok-value)
         "types.rkt"
         "sql/ast.rkt"
         "sql/dialect.rkt"
         "sql/print.rkt"
         "translate.rkt")

(provide
 (contract-out
  [translate-library (->* (elm-library?) (#:dialect dialect? #:measure (or/c hash? #f)) sql-with?)]
  [cql->sql (->* (string?) (#:dialect dialect? #:measure (or/c hash? #f)) string?)]))

;; cql->sql : String [#:dialect #:measure] -> String
(define (cql->sql cql-text #:dialect [d sqlite] #:measure [measure #f])
  (define p (parse-cql cql-text))
  (unless (ok? p) (error 'cql->sql "parse failed: ~a" p))
  (define c (compile-library (ok-value p)))
  (unless (ok? c) (error 'cql->sql "compile failed: ~a" c))
  (define q (translate-library (ok-value c) #:dialect d #:measure measure))
  (sql->string q #:dialect (dialect-name d)))

;; translate-library : elm-library [#:dialect #:measure] -> sql-with
(define (translate-library lib #:dialect [d sqlite] #:measure [measure #f])
  (match-define (elm-library lib-name lib-ver usings includes params condefs vsdefs csdefs concepts contexts defs) lib)
  (define valuesets (for/hash ([vs vsdefs]) (values (elm-valueset-def-name vs) (elm-valueset-def-id vs))))
  (define params-map (for/hash ([p params]) (values (elm-parameter-def-name p) p)))

  ;; Exclude standard "Patient" singleton from explicit CTEs
  (define user-defs (filter (lambda (d) (not (equal? (elm-def-name d) "Patient"))) defs))
  (define defs-by-name (for/hash ([d user-defs]) (values (elm-def-name d) d)))

  ;; Dependency graph of user definitions
  (define sorted-names (topological-sort user-defs defs-by-name))

  ;; Progressively translate each define in dependency order
  (define-values (ctes defs-info)
    (for/fold ([acc-ctes '()] [env-defs (hash)]) ([name sorted-names])
      (define d-def (hash-ref defs-by-name name))
      (define-values (cte dinfo) (translate-def d-def d valuesets params-map env-defs))
      (values (append acc-ctes (list cte)) (hash-set env-defs name dinfo))))

  ;; Final population query from measure criteria or library populations
  (define final-query (measure-final-query measure defs-info sorted-names))
  (sql-with ctes final-query))

;; topological-sort : (listof elm-def) (hash String elm-def) -> (listof String)
(define (topological-sort defs-list by-name)
  (define visited (mutable-set))
  (define order '())
  (define (visit name)
    (unless (set-member? visited name)
      (set-add! visited name)
      (define d (hash-ref by-name name #f))
      (when d
        (for ([dep (def-deps (elm-def-expression d))])
          (when (hash-has-key? by-name dep)
            (visit dep))))
      (set! order (cons name order))))
  (for ([d defs-list]) (visit (elm-def-name d)))
  (reverse order))

;; def-deps : ELM -> (listof String)
(define (def-deps expr)
  (define deps (mutable-set))
  (let loop ([x expr])
    (cond
      [(elm-expression-ref? x) (set-add! deps (elm-expression-ref-name x))]
      [(struct? x)
       (for ([f (vector->list (struct->vector x))]) (loop f))]
      [(list? x) (for ([el x]) (loop el))]
      [(hash? x) (for ([(_k v) (in-hash x)]) (loop v))]))
  (set->list deps))

;; translate-def : elm-def dialect valuesets params-map env-defs -> (values (cons String SqlQuery) def-info)
(define (translate-def d d-dialect valuesets params-map env-defs)
  (define name (elm-def-name d))
  (define expr (elm-def-expression d))
  (define table-name (def-name->table-name name))
  (define tbl-alias (def-name->alias name))

  ;; Check if this define is a query over a retrieve (relational)
  (cond
    [(and (elm-query? expr) (pair? (elm-query-sources expr)) (elm-retrieve? (cdar (elm-query-sources expr))))
     (define tenv-rel (make-tenv #:dialect d-dialect #:defs env-defs #:params params-map #:valuesets valuesets #:context 'Patient))
     (define term-rel (translate expr tenv-rel))
     (define dinfo (def-info table-name tbl-alias "id" 'Relation 'relation))
     (values (cons table-name (term-sql term-rel)) dinfo)]

    ;; Check if this define evaluates to a scalar / arithmetic in Patient context
    [(or (elm-precision-op? expr)
         (and (elm-property? expr) (elm-expression-ref? (elm-property-source expr)) (equal? (elm-expression-ref-name (elm-property-source expr)) "Patient")))
     (define tenv-scalar (make-tenv #:dialect d-dialect #:defs env-defs #:params params-map #:valuesets valuesets #:context 'Patient))
     (define term-s (translate expr tenv-scalar))
     (define col-name (if (elm-precision-op? expr) "age" "v"))
     (define sel (select (cons (sql-ref "p" "id") "patient_id")
                         (cons (term-sql term-s) col-name)
                         #:from (list (sql-table "patient" "p"))))
     (define dinfo (def-info table-name tbl-alias col-name (term-type term-s) 'scalar))
     (values (cons table-name sel) dinfo)]

    ;; Boolean define / population criterion
    [else
     (define referenced-defs (filter (lambda (n) (hash-has-key? env-defs n)) (def-deps expr)))
     (define joins
       (for/list ([ref-name referenced-defs])
         (define rd (hash-ref env-defs ref-name))
         (match (def-info-kind rd)
           [(or 'scalar 'boolean)
            (cons (sql-table (def-info-table rd) (def-info-alias rd))
                  (sql-bin "=" (sql-ref (def-info-alias rd) "patient_id") (sql-ref "p" "id")))]
           [_ #f])))
     (define valid-joins (filter values joins))
     (define from-clause
       (if (null? valid-joins)
           (list (sql-table "patient" "p"))
           (list (for/fold ([cur (sql-table "patient" "p")]) ([j valid-joins])
                   (sql-join #f cur (car j) (cdr j))))))

     (define tenv-bool (make-tenv #:dialect d-dialect #:defs env-defs #:params params-map #:valuesets valuesets #:context 'Patient))
     (define term-b (translate expr tenv-bool))
     (define value-expr (if (eq? (term-type term-b) 'Boolean) (sql-call "coalesce" (list (term-sql term-b) (sql-lit 0))) (term-sql term-b)))
     (define sel (select (cons (sql-ref "p" "id") "patient_id")
                         (cons value-expr "v")
                         #:from from-clause))
     (define dinfo (def-info table-name tbl-alias "v" 'Boolean 'boolean))
     (values (cons table-name sel) dinfo)]))

;; measure-final-query : (or/c hash? #f) (hash String def-info) (listof String) -> SqlSelect
(define (measure-final-query measure defs-info sorted-names)
  (define ip-name (or (find-pop-define measure "initial-population") "Initial Population"))
  (define denom-name (or (find-pop-define measure "denominator") "Denominator"))
  (define numer-name (or (find-pop-define measure "numerator") "Numerator"))
  (define excl-name (find-pop-define measure "denominator-exclusion"))

  (define ip-info (hash-ref defs-info ip-name #f))
  (define denom-info (hash-ref defs-info denom-name #f))
  (define numer-info (hash-ref defs-info numer-name #f))
  (define excl-info (and excl-name (hash-ref defs-info excl-name #f)))

  (define ip-tbl (if ip-info (def-info-table ip-info) "initial_population"))
  (define ip-alias (if ip-info (def-info-alias ip-info) "ip"))

  (define joins '())
  (define from-root (sql-table ip-tbl ip-alias))

  (define from-item
    (for/fold ([cur from-root]) ([target (list denom-info numer-info excl-info)] #:when target)
      (sql-join #f cur (sql-table (def-info-table target) (def-info-alias target))
                (sql-bin "=" (sql-ref (def-info-alias target) "patient_id") (sql-ref ip-alias "patient_id")))))

  (define denom-expr
    (if denom-info (sql-ref (def-info-alias denom-info) "v") (sql-ref ip-alias "v")))
  (define numer-expr
    (if numer-info (sql-ref (def-info-alias numer-info) "v") sql-false))

  (select (cons (sql-ref ip-alias "patient_id") "patient_id")
          (cons (sql-ref ip-alias "v") "initial-population")
          (cons denom-expr "denominator")
          (cons (sql-bin "AND" denom-expr numer-expr) "numerator")
          #:from (list from-item)
          #:order-by (list (cons (sql-ref ip-alias "patient_id") 'asc))))

;; find-pop-define : (or/c hash? #f) String -> (or/c String #f)
(define (find-pop-define measure code)
  (and measure
       (for*/first ([g (hash-ref measure 'group '())]
                    [p (hash-ref g 'population '())]
                    #:when (equal? code (hash-ref (car (hash-ref (hash-ref p 'code) 'coding)) 'code #f)))
         (hash-ref (hash-ref p 'criteria) 'expression))))

(define (def-name->table-name s)
  (string-downcase (regexp-replace* #px"[^a-zA-Z0-9]+" s "_")))

(define (def-name->alias s)
  (match s
    ["Initial Population" "ip"]
    ["Denominator" "d"]
    ["Numerator" "n"]
    ["Age at End of Period" "a"]
    ["Mammograms During Period" "m"]
    [_ (string-downcase (substring (regexp-replace* #px"[^a-zA-Z0-9]" s "") 0 (min 2 (string-length (regexp-replace* #px"[^a-zA-Z0-9]" s "")))))]))

(module+ test
  (require rackunit
           racket/file
           racket/path
           json
           db
           (only-in sql-on-fhir/operations view-rows)
           (only-in fhir/data-source current-data-source resources->data-source)
           (only-in cql/measure evaluate-measure measure-report)
           net/base64)

  (define cql-str (file->string "demo/BreastScreeningDemo.cql"))
  (define measure-json (call-with-input-file "demo/measure.json" read-json))
  (define valueset-json (call-with-input-file "demo/valueset-mammography.json" read-json))
  (define generated-sql (cql->sql cql-str #:measure measure-json))
  (check-true (string? generated-sql))
  (check-true (string-contains? generated-sql "initial_population"))
  (check-true (string-contains? generated-sql "mammograms_during_period"))

  ;; End-to-end test comparing generated SQL against CQL interpreter over the demo cohort
  (define (json-files dir)
    (sort (for/list ([f (directory-list dir #:build? #t)] #:when (regexp-match? #rx"[.]json$" (path->string f))) f)
          string<? #:key path->string))

  (define (cql-library f url)
    (define name (path->string (path-replace-extension (file-name-from-path f) #"")))
    (hasheq 'resourceType "Library" 'id name 'name name 'url url
            'content (list (hasheq 'contentType "text/cql"
                                   'data (bytes->string/utf-8 (base64-encode (file->bytes f) #""))))))

  (define resources
    (append* (for/list ([f (json-files "demo/patients")])
               (for/list ([e (hash-ref (call-with-input-file f read-json) 'entry)]) (hash-ref e 'resource)))))

  (define pids (for/list ([r resources] #:when (equal? (hash-ref r 'resourceType) "Patient")) (hash-ref r 'id)))

  ;; 1. Run interpreter
  (define libs (list (cql-library "demo/BreastScreeningDemo.cql" "http://example.org/fhir/Library/BreastScreeningDemo")
                     (cql-library "demo/FHIRHelpers.cql" "http://hl7.org/fhir/Library/FHIRHelpers")))
  (define-values (interp-individual interp-summary)
    (parameterize ([current-data-source (resources->data-source (append (list measure-json valueset-json) libs resources))])
      (values (for/hash ([pid pids])
                (values pid (evaluate-measure measure-json "2025-01-01" "2025-12-31" #:subject (string-append "Patient/" pid) #:offset 0)))
              (evaluate-measure measure-json "2025-01-01" "2025-12-31" #:offset 0))))

  ;; 2. Run generated SQL
  (define c (sqlite3-connect #:database 'memory))
  (for ([f (json-files "demo/views")])
    (define view (call-with-input-file f read-json))
    (define cols (for*/list ([s (hash-ref view 'select)] [col (hash-ref s 'column)]) (hash-ref col 'name)))
    (define table (hash-ref view 'name))
    (query-exec c (format "CREATE TABLE ~a (~a)" table (string-join cols ", ")))
    (define insert (format "INSERT INTO ~a VALUES (~a)" table (string-join (map (lambda (_c) "?") cols) ", ")))
    (for ([row (view-rows view resources)])
      (apply query-exec c insert (for/list ([col cols])
                                   (define v (hash-ref row (string->symbol col) 'null))
                                   (if (eq? v 'null) sql-null v)))))

  (query-exec c "CREATE TABLE IF NOT EXISTS valueset_code (url, system, code)")
  (for ([cc (hash-ref (hash-ref valueset-json 'expansion) 'contains)])
    (query-exec c "INSERT INTO valueset_code VALUES (?, ?, ?)" (hash-ref valueset-json 'url) (hash-ref cc 'system) (hash-ref cc 'code)))

  (define sql-params (hash "period_start" "2025-01-01T00:00:00.000Z" "period_end" "2025-12-31T23:59:59.999Z"))
  (define bound-sql
    (regexp-replace* #px":([a-z_]+)" generated-sql
                     (lambda (all name) (format "'~a'" (hash-ref sql-params name)))))

  (define result (query c bound-sql))
  (define names (map (lambda (h) (cdr (assq 'name h))) (rows-result-headers result)))
  (define pops
    (for/hash ([row (rows-result-rows result)])
      (define cells (map cons names (vector->list row)))
      (values (cdr (assoc "patient_id" cells))
              (for/hash ([cell cells] #:unless (equal? (car cell) "patient_id"))
                (values (car cell) (if (memv (cdr cell) '(1 #t)) 1 0))))))
  (disconnect c)

  ;; 3. Build SQL MeasureReports and assert identical to interpreter
  (define (sql-report counts subject) (measure-report measure-json (list counts) "2025-01-01" "2025-12-31" subject))
  (for ([pid pids])
    (check-equal? (sql-report (hash-ref pops pid) (string-append "Patient/" pid))
                  (hash-ref interp-individual pid)
                  (format "Patient ~a individual report mismatch" pid)))

  (define summary-counts
    (for*/fold ([acc (hash)]) ([(_pid h) (in-hash pops)] [(k v) (in-hash h)]) (hash-update acc k (lambda (n) (+ n v)) 0)))
  (check-equal? (sql-report summary-counts #f)
                interp-summary
                "Summary report mismatch"))
