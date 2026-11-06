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
;;; A Suite report is (report name pass fail untranslatable skip failures missing):
;;;   failures : (listof (list test-name expression expected got))
;;;   missing  : hash String -> Natural   untranslatable constructs by message, counted

(require racket/contract racket/list racket/string racket/path xml
         (only-in cql/parser/parse parse-cql-expr)
         (only-in cql/compile compile-expr)
         (only-in cql/interp eval-elm make-ienv test-equal?)
         (only-in cql/value cql-null? render)
         (only-in fhir/result/result ok? ok-value)
         "../translate.rkt"
         "../run.rkt")

(provide
 (struct-out report)
 (contract-out
  [tck-suites (listof path?)]
  [run-tck-suite (-> path-string? report?)]
  [run-tck (-> (listof report?))]))

(struct report (name pass fail untranslatable skip failures missing) #:transparent)

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
(define (all-tests doc)
  (let loop ([x (document-element doc)])
    (cond [(and (element? x) (eq? (element-name x) 'test)) (list x)]
          [(element? x) (append-map loop (element-content x))]
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
    [(not elm) (values 'skip #f)]
    [(and out (not expected-elm)) (values 'skip #f)]
    [else
     (with-handlers ([exn:fail:untranslatable? (lambda (e) (values 'untranslatable (exn-message e)))]
                     [exn:fail:sql-run? (lambda (e) (values 'fail (list "SQL error" (exn-message e) (exn:fail:sql-run-sql e))))]
                     [exn:fail? (lambda (e) (values 'fail (list "error" (exn-message e) "")))])
       (define got (run-expression elm))
       (cond
         [(not out) (values 'pass #f)]
         [else
          (define expected (with-handlers ([exn:fail? (lambda (_) 'unevaluable)]) (eval-elm expected-elm (make-ienv))))
          (cond [(eq? expected 'unevaluable) (values 'skip #f)]
                [(test-equal? got expected) (values 'pass #f)]
                [else (values 'fail (list (safe-render expected) (safe-render got) (expression-sql elm)))])]))]))

(define (safe-render v) (with-handlers ([exn:fail? (lambda (_) "<unrenderable>")]) (if (cql-null? v) "null" (render v))))

;; run-tck-suite : Path -> Report
(define (run-tck-suite path)
  (define doc (call-with-input-file path read-xml))
  (define counts (make-hasheq))
  (define missing (make-hash))
  (define failures '())
  (for ([t (all-tests doc)])
    (define ex (child t 'expression))
    (define result
      (cond
        [(not ex) 'skip]
        [(attr ex 'invalid) 'skip]
        [else
         (define out (let ([o (child t 'output)]) (and o (elem-text o))))
         (define-values (r detail) (run-test (elem-text ex) out))
         (case r
           [(untranslatable) (hash-update! missing (generalize detail) add1 0)]
           [(fail) (set! failures (cons (list (or (attr t 'name) "?") (elem-text ex) detail) failures))])
         r]))
    (hash-update! counts result add1 0))
  (report (path->string (file-name-from-path path))
          (hash-ref counts 'pass 0) (hash-ref counts 'fail 0) (hash-ref counts 'untranslatable 0) (hash-ref counts 'skip 0)
          (reverse failures) missing))

;; generalize : String -> String   an untranslatable message without its specifics, for counting
(define (generalize msg) (regexp-replace* #px"[0-9]+" msg "#"))

(define (run-tck) (map run-tck-suite tck-suites))

(module+ main
  (define verbose? (member "-v" (vector->list (current-command-line-arguments))))
  (define reports (run-tck))
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
