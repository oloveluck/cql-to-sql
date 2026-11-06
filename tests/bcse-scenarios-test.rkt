#lang racket/base

;;; bcse-scenarios-test.rkt — the BCS-E scenarios (scenarios/bcse) against the HEDIS core IG and
;;; against the measure.
;;;
;;; Checked now:
;;; - every scenario compiles with fsh and validates against the HEDIS core and CARIN BB profiles it
;;;   claims (scripts/bcse-check.rkt: 0 errors);
;;; - every scenario Bundle carries one scorekey whose values agree with the measure's own
;;;   definitions: Denominator = Initial population and not Exclusion, and the same for the Medicare
;;;   group.
;;; Pending: the evaluation of BCS-E itself (BCSE_Details) over each scenario, compared with its
;;; scorekey. That needs the cql compiler to translate NCQA's libraries (Niko is fixing it); until
;;; all of them compile, this reports how many do and skips the evaluation.
;;;
;;; Needs the packages in vendor/packages: run `racket scripts/install-hedis.rkt` first (and one
;;; `sushi build scenarios/bcse` before it, so SUSHI's cache holds the dependencies). Without them
;;; the test says so and checks nothing.

(require rackunit
         racket/list
         racket/runtime-path
         json
         net/base64
         (only-in fsh/check check-report-diagnostics check-report-examples check-report-invalid check-report-artifacts)
         (only-in fhir/diagnostic diagnostic-severity diagnostic->string)
         (only-in fhir/result/result ok? ok-value)
         (only-in cql/parser/parse parse-cql)
         (only-in cql/compile compile-library/errors current-library-resolver)
         "../scripts/bcse-check.rkt")

(define-runtime-path repo "..")
(define packages (build-path repo "vendor" "packages" "ncqa.hedis.core.main.v2025-2025.1.0.tgz"))

(define population-names
  '("Initial population" "Exclusion" "Denominator" "Numerator" "Exclusion - Medicare" "Denominator - Medicare"))

;; scorekey-values : Parameters -> (hash String Boolean)
(define (scorekey-values p)
  (for/hash ([x (hash-ref p 'parameter '())]) (values (hash-ref x 'name) (hash-ref x 'valueBoolean))))

;; libraries-compiling : -> (values Natural Natural)   BCS-E's libraries that compile, of all of them
(define (libraries-compiling)
  (define b (call-with-input-file (build-path repo "BCSE_Details-2025.3.0.bundle.json") read-json))
  (define parsed
    (for*/hash ([e (hash-ref b 'entry)] [r (in-value (hash-ref e 'resource))]
                #:when (equal? (hash-ref r 'resourceType) "Library")
                [c (hash-ref r 'content '())] #:when (equal? (hash-ref c 'contentType #f) "text/cql"))
      (values (hash-ref r 'name)
              (parse-cql (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref c 'data))))))))
  (define (resolver name version) (let ([p (hash-ref parsed name #f)]) (and p (ok? p) (ok-value p))))
  (define clean
    (parameterize ([current-library-resolver resolver])
      (for/sum ([(n p) parsed])
        (if (and (ok? p)
                 (let-values ([(lib errs) (with-handlers ([exn:fail? (lambda (_) (values #f '(crash)))])
                                            (compile-library/errors (ok-value p)))])
                   (and lib (null? errs))))
            1 0))))
  (values clean (hash-count parsed)))

(cond
  [(not (file-exists? packages))
   (printf "BCS-E scenarios: SKIPPED, no HEDIS packages in vendor/packages (run racket scripts/install-hedis.rkt)\n")]
  [else
   ;; conformance
   (define r (check-scenarios))
   (define errors (filter (lambda (d) (eq? (diagnostic-severity d) 'error)) (check-report-diagnostics r)))
   (for ([d errors]) (printf "  ~a\n" (diagnostic->string d)))
   (printf "BCS-E scenarios: ~a examples validated, ~a invalid\n" (check-report-examples r) (check-report-invalid r))
   (check-equal? (length errors) 0 "every scenario conforms to the HEDIS core profiles")
   (check-true (>= (check-report-examples r) 89) "fewer scenario examples than the floor")

   ;; scorekeys: one per scenario Bundle, consistent with the measure's definitions
   (define artifacts (check-report-artifacts r))
   (define by-id (for/hash ([a artifacts]) (values (cons (hash-ref a 'resourceType) (hash-ref a 'id)) a)))
   (define bundles (filter (lambda (a) (and (equal? (hash-ref a 'resourceType) "Bundle")
                                            (regexp-match? #rx"^bcse-[0-9]+$" (hash-ref a 'id))))
                           artifacts))
   (check-true (>= (length bundles) 19) "fewer scenarios than the floor")
   (for ([b bundles])
     (define id (hash-ref b 'id))
     (define key (hash-ref by-id (cons "Parameters" (string-append id ".scorekey")) #f))
     (check-true (and key #t) (format "~a has a scorekey" id))
     (when key
       (define v (scorekey-values key))
       (check-equal? (sort (hash-keys v) string<?) (sort population-names string<?) (format "~a's scorekey names the populations" id))
       (check-equal? (hash-ref v "Denominator") (and (hash-ref v "Initial population") (not (hash-ref v "Exclusion")))
                     (format "~a: Denominator = Initial population and not Exclusion" id))
       (check-equal? (hash-ref v "Denominator - Medicare")
                     (and (hash-ref v "Initial population") (not (hash-ref v "Exclusion - Medicare")))
                     (format "~a: Denominator - Medicare = Initial population and not Exclusion - Medicare" id))))

   ;; the measure itself
   (define-values (clean total) (libraries-compiling))
   (if (< clean total)
       (printf "BCS-E evaluation: PENDING, ~a/~a of the measure's libraries compile (the cql compiler work for NCQA's CQL)\n" clean total)
       (printf "BCS-E evaluation: all ~a libraries compile; evaluate each scenario against its scorekey here next\n" total))])
