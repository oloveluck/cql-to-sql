#lang racket/base

;;; tck.rkt — the HL7 CQL test suite (cql's vendored tests/vendor/cql-tests) through SQL.
;;;
;;; For each expression test: compile the CQL to ELM (cql), translate to SQL, run it in SQLite,
;;; decode the result and compare it with the expected <output>, which the interpreter evaluates —
;;; the same comparison (test-equal?) the interpreter's own TCK run uses.
;;;
;;; A TestResult is one of:
;;;   'pass            the SQL result equals the expected value
;;;   'fail            a different value, or a SQL runtime error where a value was expected
;;;   'untranslatable  the translator reports a construct it has no SQL for (never wrong SQL)
;;;   'skip            outside the SQL backend's question: tests that must fail to compile, tests
;;;                    whose expression or expected output the cql compiler itself rejects
;;; A Suite report is (report name pass fail untranslatable skip failures missing tests):
;;;   failures : (listof (list test-name expression expected got))
;;;   missing  : hash String -> Natural   untranslatable constructs by message, counted
;;;   tests    : (listof TestRecord), every test in suite order
;;; A TestRecord is (test-record group name expression expected result detail): detail is the
;;; untranslatable construct, the failure (expected, got, SQL), the SQL of a pass, or why a test
;;; was skipped

(require racket/contract racket/list racket/string racket/path racket/match xml
         (only-in json write-json)
         (only-in cql/parser/parse parse-cql-expr)
         (only-in cql/compile compile-expr)
         (only-in cql/interp eval-elm make-ienv test-equal?)
         (only-in cql/value cql-null? render)
         (only-in fhir/result/result ok? ok-value)
         "../translate.rkt"
         "../run.rkt")

(provide
 (struct-out report)
 (struct-out test-record)
 (contract-out
  [tck-suites (listof path?)]
  [run-tck-suite (-> path-string? report?)]
  [run-tck (-> (listof report?))]))

(struct report (name pass fail untranslatable skip failures missing tests) #:transparent)
(struct test-record (group name expression expected result detail) #:transparent)

(define cql-tests-dir
  (let ([p (collection-file-path "cql-tests" "cql" "tests" "vendor")]) p))

(define tck-suites
  (sort (for/list ([f (directory-list cql-tests-dir #:build? #t)] #:when (regexp-match? #rx"[.]xml$" (path->string f))) f)
        string<? #:key path->string))

;; ---- XML ----
(define (children e name) (filter (lambda (c) (and (element? c) (eq? (element-name c) name))) (element-content e)))
(define (child e name) (let ([cs (children e name)]) (and (pair? cs) (car cs))))
(define (attr e name) (for/first ([a (element-attributes e)] #:when (eq? (attribute-name a) name)) (attribute-value a)))
(define (elem-text e) (string-trim (apply string-append (for/list ([c (element-content e)] #:when (pcdata? c)) (pcdata-string c)))))
(define (all-tests doc)   ; -> (listof (cons group-name test-element))
  (let loop ([x (document-element doc)] [group #f])
    (cond [(and (element? x) (eq? (element-name x) 'test)) (list (cons group x))]
          [(element? x) (append-map (lambda (c) (loop c (if (eq? (element-name x) 'group) (or (attr x 'name) group) group)))
                                    (element-content x))]
          [else '()])))

;; compile : String -> (or ELM #f)
(define (compile str)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define p (parse-cql-expr str))
    (and (ok? p) (let ([c (compile-expr (ok-value p))]) (and (ok? c) (ok-value c))))))

;; run-test : String (or String #f) -> (values TestResult detail)
(define (run-test expr out)
  (define elm (compile expr))
  (define expected-elm (and out (compile out)))
  (cond
    [(not elm) (values 'skip "the cql compiler rejects the expression")]
    [(and out (not expected-elm)) (values 'skip "the cql compiler rejects the expected output")]
    [else
     (with-handlers ([exn:fail:untranslatable? (lambda (e) (values 'untranslatable (exn-message e)))]
                     [exn:fail:sql-run? (lambda (e) (values 'fail (list "SQL error" (exn-message e) (exn:fail:sql-run-sql e))))]
                     [exn:fail? (lambda (e) (values 'fail (list "error" (exn-message e) "")))])
       (define got (run-expression elm))
       (cond
         [(not out) (values 'pass (expression-sql elm))]
         [else
          (define expected (with-handlers ([exn:fail? (lambda (_) 'unevaluable)]) (eval-elm expected-elm (make-ienv))))
          (cond [(eq? expected 'unevaluable) (values 'skip "the interpreter cannot evaluate the expected output")]
                [(test-equal? got expected) (values 'pass (expression-sql elm))]
                [else (values 'fail (list (safe-render expected) (safe-render got) (expression-sql elm)))])]))]))

(define (safe-render v) (with-handlers ([exn:fail? (lambda (_) "<unrenderable>")]) (if (cql-null? v) "null" (render v))))

;; run-tck-suite : Path -> Report
(define (run-tck-suite path)
  (define doc (call-with-input-file path read-xml))
  (define counts (make-hasheq))
  (define missing (make-hash))
  (define failures '())
  (define records
    (for/list ([gt (all-tests doc)])
      (define group (car gt)) (define t (cdr gt))
      (define name (or (attr t 'name) "?"))
      (define ex (child t 'expression))
      (define out (let ([o (child t 'output)]) (and o (elem-text o))))
      (define-values (result detail)
        (cond
          [(not ex) (values 'skip "a library test, outside the expression suite")]
          [(attr ex 'invalid) (values 'skip "the test expects the expression to be rejected")]
          [else
           (define-values (r detail) (run-test (elem-text ex) out))
           (case r
             [(untranslatable) (hash-update! missing (generalize detail) add1 0)]
             [(fail) (set! failures (cons (list name (elem-text ex) detail) failures))])
           (values r detail)]))
      (hash-update! counts result add1 0)
      (test-record group name (if ex (elem-text ex) "") out result detail)))
  (report (path->string (file-name-from-path path))
          (hash-ref counts 'pass 0) (hash-ref counts 'fail 0) (hash-ref counts 'untranslatable 0) (hash-ref counts 'skip 0)
          (reverse failures) missing records))

;; generalize : String -> String   an untranslatable message without its specifics, for counting
(define (generalize msg) (regexp-replace* #px"[0-9]+" msg "#"))

(define (run-tck) (map run-tck-suite tck-suites))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define verbose? (member "-v" args))
  (define json-out (let ([m (member "--json" args)]) (and m (pair? (cdr m)) (cadr m))))
  (define reports (run-tck))
  ;; --json <file>: every test with its result, for reports
  (when json-out
    (call-with-output-file json-out #:exists 'replace
      (lambda (o)
        (write-json
         (for*/list ([r reports] [t (report-tests r)])
           (hasheq 'suite (regexp-replace #rx"[.]xml$" (report-name r) "") 'group (or (test-record-group t) "")
                   'name (test-record-name t) 'expression (test-record-expression t)
                   'expected (or (test-record-expected t) 'null) 'result (symbol->string (test-record-result t))
                   'detail (match (test-record-detail t)
                             [#f 'null] [(? string? d) d]
                             [(list a b c) (hasheq 'expected (format "~a" a) 'got (format "~a" b) 'sql (format "~a" c))]
                             [d (format "~a" d)])))
         o))))
  (for ([r reports])
    (printf "~a: ~a pass, ~a fail, ~a untranslatable, ~a skip\n"
            (report-name r) (report-pass r) (report-fail r) (report-untranslatable r) (report-skip r))
    (when verbose?
      (for ([f (report-failures r)]) (printf "  FAIL ~a: ~a\n      ~s\n" (car f) (cadr f) (caddr f)))))
  (define (total f) (for/sum ([r reports]) (f r)))
  (printf "TOTAL: ~a pass, ~a fail, ~a untranslatable, ~a skip\n"
          (total report-pass) (total report-fail) (total report-untranslatable) (total report-skip))
  (when verbose?
    (define missing (make-hash))
    (for* ([r reports] [(k v) (in-hash (report-missing r))]) (hash-update! missing k (lambda (n) (+ n v)) 0))
    (printf "untranslatable, most common first:\n")
    (for ([kv (take (sort (hash->list missing) > #:key cdr) (min 40 (hash-count missing)))])
      (printf "  ~a  ~a\n" (cdr kv) (car kv)))))
