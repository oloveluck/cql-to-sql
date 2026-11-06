#lang racket/base

;;; run.rkt — the demo: one measure, two evaluators, the same MeasureReports.
;;;
;;;   interpreter: BreastScreeningDemo.cql run by cql/measure's evaluate-measure over the patients
;;;   SQL:         the patients flattened by the demo's ViewDefinitions (sql-on-fhir) into SQLite
;;;                tables, BreastScreeningDemo.sql run over them, its per-patient population rows
;;;                made into MeasureReports by the same report builder (cql/measure's measure-report)
;;;
;;; Each patient's `individual` report and the `summary` report must be equal. `racket demo/run.rkt`
;;; prints the comparison and writes the reports to demo/out/; the test submodule checks equality.

(require racket/contract racket/file racket/list racket/path racket/runtime-path racket/string
         json net/base64
         (only-in db sqlite3-connect disconnect query query-exec sql-null rows-result-headers rows-result-rows)
         (only-in fhir/data-source current-data-source resources->data-source)
         (only-in sql-on-fhir/operations view-rows)
         (only-in cql/measure evaluate-measure measure-report))

(provide
 (contract-out
  [run-demo (-> (listof (list/c string? hash? hash?)))]))   ; (patient-id interpreter-report sql-report)

(define-runtime-path here ".")

(define period-start "2025-01-01")
(define period-end "2025-12-31")
;; the Measurement Period the interpreter builds from those days (UTC, end inclusive)
(define sql-params (hash "period_start" "2025-01-01T00:00:00.000Z" "period_end" "2025-12-31T23:59:59.999Z"))

(define (read-json-file f) (call-with-input-file f read-json))
(define (json-files dir)
  (sort (for/list ([f (directory-list dir #:build? #t)] #:when (regexp-match? #rx"[.]json$" (path->string f))) f)
        string<? #:key path->string))

;; a .cql file as the Library resource a FHIR server would hold
(define (cql-library f url)
  (define name (path->string (path-replace-extension (file-name-from-path f) #"")))
  (hasheq 'resourceType "Library" 'id name 'name name 'url url
          'content (list (hasheq 'contentType "text/cql"
                                 'data (bytes->string/utf-8 (base64-encode (file->bytes f) #""))))))

;; the patients' resources, Bundles unwrapped
(define (patient-resources)
  (append* (for/list ([f (json-files (build-path here "patients"))])
             (for/list ([e (hash-ref (read-json-file f) 'entry)]) (hash-ref e 'resource)))))

;; ---- the interpreter side ---------------------------------------------------------------------
(define (interpreter-reports measure valueset resources pids)
  (define libs (list (cql-library (build-path here "BreastScreeningDemo.cql") "http://example.org/fhir/Library/BreastScreeningDemo")
                     (cql-library (build-path here "FHIRHelpers.cql") "http://hl7.org/fhir/Library/FHIRHelpers")))
  (parameterize ([current-data-source (resources->data-source (append (list measure valueset) libs resources))])
    (values (for/hash ([pid pids])
              (values pid (evaluate-measure measure period-start period-end #:subject (string-append "Patient/" pid) #:offset 0)))
            (evaluate-measure measure period-start period-end #:offset 0))))

;; ---- the SQL side -----------------------------------------------------------------------------
;; load-view! : connection ViewDefinition resources -> void   the view's rows as a table named for it
(define (load-view! c view resources)
  (define cols (for*/list ([s (hash-ref view 'select)] [col (hash-ref s 'column)]) (hash-ref col 'name)))
  (define table (hash-ref view 'name))
  (query-exec c (format "CREATE TABLE ~a (~a)" table (string-join cols ", ")))
  (define insert (format "INSERT INTO ~a VALUES (~a)" table (string-join (map (lambda (_c) "?") cols) ", ")))
  (for ([row (view-rows view resources)])
    (apply query-exec c insert (for/list ([col cols])
                                 (define v (hash-ref row (string->symbol col) 'null))
                                 (if (eq? v 'null) sql-null v)))))

;; load-valueset! : connection ValueSet -> void   its expansion as valueset_code rows
(define (load-valueset! c vs)
  (query-exec c "CREATE TABLE IF NOT EXISTS valueset_code (url, system, code)")
  (for ([cc (hash-ref (hash-ref vs 'expansion) 'contains)])
    (query-exec c "INSERT INTO valueset_code VALUES (?, ?, ?)" (hash-ref vs 'url) (hash-ref cc 'system) (hash-ref cc 'code))))

;; bind-params : String -> String   :name parameters as SQL string literals (the demo's fixed values)
(define (bind-params sql)
  (regexp-replace* #px":([a-z_]+)" sql
                   (lambda (all name) (format "'~a'" (hash-ref sql-params name (lambda () (error 'demo "no parameter ~a" name)))))))

;; sql-populations : resources ValueSet -> (hash patient-id -> (hash code -> 0|1))
(define (sql-populations resources valueset)
  (define c (sqlite3-connect #:database 'memory))
  (for ([f (json-files (build-path here "views"))]) (load-view! c (read-json-file f) resources))
  (load-valueset! c valueset)
  (define result (query c (bind-params (file->string (build-path here "BreastScreeningDemo.sql")))))
  (define names (map (lambda (h) (cdr (assq 'name h))) (rows-result-headers result)))
  (begin0
    (for/hash ([row (rows-result-rows result)])
      (define cells (map cons names (vector->list row)))
      (values (cdr (assoc "patient_id" cells))
              (for/hash ([cell cells] #:unless (equal? (car cell) "patient_id"))
                (values (car cell) (if (memv (cdr cell) '(1 #t)) 1 0)))))
    (disconnect c)))

;; ---- the comparison ---------------------------------------------------------------------------
(define (run-demo)
  (define measure (read-json-file (build-path here "measure.json")))
  (define valueset (read-json-file (build-path here "valueset-mammography.json")))
  (define resources (patient-resources))
  (define pids (for/list ([r resources] #:when (equal? (hash-ref r 'resourceType) "Patient")) (hash-ref r 'id)))
  (define-values (interp-individual interp-summary) (interpreter-reports measure valueset resources pids))
  (define pops (sql-populations resources valueset))
  (define (sql-report counts subject) (measure-report measure (list counts) period-start period-end subject))
  (define summary-counts
    (for*/fold ([acc (hash)]) ([(_pid h) (in-hash pops)] [(k v) (in-hash h)]) (hash-update acc k (lambda (n) (+ n v)) 0)))
  (append
   (for/list ([pid pids])
     (list pid (hash-ref interp-individual pid) (sql-report (hash-ref pops pid) (string-append "Patient/" pid))))
   (list (list "summary" interp-summary (sql-report summary-counts #f)))))

;; counts : MeasureReport -> String   "IP/D/N" for the first group
(define (counts report)
  (define g (car (hash-ref report 'group)))
  (define (c code) (for/first ([p (hash-ref g 'population)] #:when (equal? code (hash-ref (car (hash-ref (hash-ref p 'code) 'coding)) 'code)))
                     (hash-ref p 'count)))
  (format "~a/~a/~a~a" (c "initial-population") (c "denominator") (c "numerator")
          (let ([s (hash-ref g 'measureScore #f)]) (if s (format "  score ~a" (real->decimal-string (hash-ref s 'value) 3)) ""))))

(module+ main
  (define results (run-demo))
  (define out (build-path here "out"))
  (make-directory* out)
  (printf "~a  ~a  ~a  ~a\n" (~ "patient" 20) (~ "interpreter IP/D/N" 26) (~ "SQL IP/D/N" 26) "same?")
  (for ([r results])
    (define-values (pid i s) (apply values r))
    (printf "~a  ~a  ~a  ~a\n" (~ pid 20) (~ (counts i) 26) (~ (counts s) 26) (if (equal? i s) "yes" "NO"))
    (with-output-to-file (build-path out (format "~a.interpreter.json" pid)) #:exists 'replace (lambda () (write-json i)))
    (with-output-to-file (build-path out (format "~a.sql.json" pid)) #:exists 'replace (lambda () (write-json s))))
  (define same (count (lambda (r) (equal? (cadr r) (caddr r))) results))
  (printf "\n~a of ~a MeasureReports identical (~a individual + summary)\n" same (length results) (sub1 (length results)))
  (unless (= same (length results)) (exit 1)))

(define (~ s w) (let ([s (format "~a" s)]) (if (>= (string-length s) w) s (string-append s (make-string (- w (string-length s)) #\space)))))

(module+ test
  (require rackunit)
  (for ([r (run-demo)])
    (check-equal? (caddr r) (cadr r) (format "~a: the SQL MeasureReport differs from the interpreter's" (car r)))))
