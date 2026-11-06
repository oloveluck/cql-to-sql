#lang racket/base

;;; build.rkt — FHIR R4 data into the relational model (spec.rkt), in SQLite.
;;;
;;;   racket model/build.rkt --out model.db [--zone-offset -07:00] <file|dir> …
;;;
;;; Reads resources (JSON resources, Bundles, NDJSON; directories recursively), repairs the invalid
;;; values the interpreter tolerates (repair.rkt; zone-less dateTimes only with --zone-offset),
;;; converts them to R6
;;; (r4-to-r6.rkt), parses each once against the R6 model, evaluates every table's ViewDefinition
;;; (sql-on-fhir's view engine) and writes the rows into SQLite with indexes on the retrieve's
;;; access paths: the resource key, patient_id, and (system, code) on coding tables.
;;;
;;; A resource that does not parse, or a table whose view fails, is reported, never dropped
;;; silently: a lost record would change a cohort without a trace.

(require racket/contract
         racket/list
         racket/string
         racket/path
         racket/file
         json
         (only-in db sqlite3-connect disconnect query-exec query-value sql-null connection? start-transaction commit-transaction)
         (only-in fhir/serialize/from-json from-json)
         (only-in fhir/result/result ok? ok-value err-error)
         (only-in sql-on-fhir/model/types)
         (only-in sql-on-fhir/view eval-view)
         "r4-to-r6.rkt"
         "repair.rkt"
         "spec.rkt")

(provide
 (struct-out build-report)
 (contract-out
  [read-resources (-> (listof path-string?) (listof hash?))]
  [build-model (->* ((listof hash?)) (#:connection connection? #:zone-offset (or/c #f string?))
                    (values connection? build-report?))]))

;; A BuildReport is (build-report resources repairs unparsed rows failures):
;;   resources : Natural                 resources read
;;   repairs   : Repairs                 values repair.rkt made valid (zone-less dateTimes, …)
;;   unparsed  : (listof (cons type id))  resources the R6 model rejected
;;   rows      : (hash table-name -> Natural)
;;   failures  : (listof (cons table-name message))
(struct build-report (resources repairs unparsed rows failures) #:transparent)

;; read-resources : (listof Path) -> (listof Resource)   Bundles unwrapped
(define (read-resources paths)
  (define (unwrap r)
    (if (equal? (hash-ref r 'resourceType #f) "Bundle")
        (for*/list ([e (hash-ref r 'entry '())] [x (in-value (hash-ref e 'resource #f))] #:when (hash? x) [y (unwrap x)]) y)
        (list r)))
  (define (read-file f)
    (define s (path->string f))
    (cond [(regexp-match? #rx"[.]ndjson$" s)
           (for*/list ([line (file->lines f)] #:unless (string=? (string-trim line) "") [r (unwrap (string->jsexpr line))]) r)]
          [(regexp-match? #rx"[.]json$" s)
           (define j (call-with-input-file f read-json))
           (if (and (hash? j) (hash-ref j 'resourceType #f)) (unwrap j) '())]
          [else '()]))
  (append* (for/list ([p paths])
             (if (directory-exists? p)
                 (append* (for/list ([f (sort (find-files file-exists? p) string<? #:key path->string)]) (read-file f)))
                 (read-file (if (path? p) p (string->path p)))))))

;; build-model : (listof Resource) [#:connection #:zone-offset] -> (values Connection BuildReport)
(define (build-model resources0 #:connection [conn #f] #:zone-offset [zone #f])
  (define c (or conn (sqlite3-connect #:database 'memory)))
  (define-values (resources repairs) (repair-resources resources0 #:zone-offset zone))
  ;; only the types the model has tables for; the rest is not read
  (define model-types (remove-duplicates (map table-resource model)))
  (define r6 (for/list ([r resources] #:when (member (hash-ref r 'resourceType #f) model-types)) (r4->r6 r)))
  ;; parse once, by type
  (define unparsed '())
  (define by-type
    (for/fold ([h (hash)]) ([r r6])
      (define p (from-json r #:lenient? #t))
      (cond [(ok? p) (hash-update h (hash-ref r 'resourceType) (lambda (l) (cons (ok-value p) l)) '())]
            [else (set! unparsed (cons (cons (hash-ref r 'resourceType #f) (hash-ref r 'id #f)) unparsed)) h])))
  (define failures '())
  (define rows
    (for/hash ([t model])
      (define cols (table-columns t))
      (query-exec c (format "CREATE TABLE ~a (~a)" (table-name t)
                            (string-join (map (lambda (n ty) (string-append n " " ty)) cols (table-column-types t)) ", ")))
      (define view (ok-value (from-json (table->view t))))
      (define nodes (reverse (hash-ref by-type (table-resource t) '())))
      (define result
        (with-handlers ([exn:fail? (lambda (e) (set! failures (cons (cons (table-name t) (exn-message e)) failures)) '())])
          (eval-view view nodes)))
      (define insert (format "INSERT INTO ~a VALUES (~a)" (table-name t) (string-join (map (lambda (_x) "?") cols) ", ")))
      (start-transaction c)
      (for ([row result])
        (apply query-exec c insert
               (for/list ([col cols]) (sql-value (cond [(assq (string->symbol col) row) => cdr] [else 'null])))))
      (commit-transaction c)
      (index! c t cols)
      (values (table-name t) (length result))))
  (values c (build-report (length resources) repairs (reverse unparsed) rows (reverse failures))))

;; sql-value : jsexpr -> SQL value   booleans as 0/1, JSON null as NULL, a list as JSON text
(define (sql-value v)
  (cond [(eq? v 'null) sql-null]
        [(eq? v #t) 1]
        [(eq? v #f) 0]
        [(or (list? v) (hash? v)) (jsexpr->string v)]
        [else v]))

;; index! : the resource key, patient_id, and (system, code)
(define (index! c t cols)
  (define (ix suffix on) (query-exec c (format "CREATE INDEX ~a_~a ON ~a (~a)" (table-name t) suffix (table-name t) on)))
  (ix "key" (car cols))
  (when (member "patient_id" cols) (ix "patient" "patient_id"))
  (when (and (member "system" cols) (member "code" cols)) (ix "code" "system, code")))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define-values (out zone inputs)
    (let loop ([as args] [out #f] [zone #f] [in '()])
      (cond [(null? as) (values out zone (reverse in))]
            [(and (equal? (car as) "--out") (pair? (cdr as))) (loop (cddr as) (cadr as) zone in)]
            [(and (equal? (car as) "--zone-offset") (pair? (cdr as))) (loop (cddr as) out (cadr as) in)]
            [else (loop (cdr as) out zone (cons (car as) in))])))
  (unless (and out (pair? inputs))
    (eprintf "usage: racket model/build.rkt --out model.db [--zone-offset -07:00] <file|dir> …\n") (exit 2))
  (when (file-exists? out) (delete-file out))
  (define resources (read-resources inputs))
  (define-values (c rep) (build-model resources #:connection (sqlite3-connect #:database out #:mode 'create) #:zone-offset zone))
  (disconnect c)
  (printf "~a resources, ~a tables, ~a rows -> ~a\n" (build-report-resources rep) (hash-count (build-report-rows rep))
          (for/sum ([(_k v) (build-report-rows rep)]) v) out)
  (let ([rp (build-report-repairs rep)])
    (unless (zero? (for/sum ([(_k v) rp]) v))
      (printf "repaired: ~a zone-less dateTimes given ~a, ~a boolean strings\n" (hash-ref rp 'zone) zone (hash-ref rp 'boolean))))
  (unless (null? (build-report-unparsed rep))
    (printf "~a resources the R6 model rejected: ~a\n" (length (build-report-unparsed rep)) (take (build-report-unparsed rep) (min 10 (length (build-report-unparsed rep))))))
  (for ([f (build-report-failures rep)]) (printf "table ~a failed: ~a\n" (car f) (cdr f)))
  (unless (and (null? (build-report-unparsed rep)) (null? (build-report-failures rep))) (exit 1)))
