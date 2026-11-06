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
;;; - the measure itself: BCSE_Details evaluated by the cql interpreter over each scenario's
;;;   resources, with the stand-in value sets and the measure's default measurement period (2025),
;;;   each population define compared with the scorekey (a null define counts as false). The
;;;   agreements have a floor that only rises, and every disagreement is named.
;;;   This needs a cql that compiles NCQA's libraries (the parser fixes, cql 2b846aa); with an
;;;   older one, the test reports how many libraries compile and skips the evaluation.
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
         (only-in cql/run load-runtime-library resources->data valuesets->terminology rlib-value)
         (only-in cql/value cql-null?)
         "../scripts/bcse-check.rkt")

(define-runtime-path repo "..")
(define packages (build-path repo "vendor" "packages" "ncqa.hedis.core.main.v2025-2025.1.0.tgz"))

(define population-names
  '("Initial population" "Exclusion" "Denominator" "Numerator" "Exclusion - Medicare" "Denominator - Medicare"))

;; scorekey-values : Parameters -> (hash String Boolean)
(define (scorekey-values p)
  (for/hash ([x (hash-ref p 'parameter '())]) (values (hash-ref x 'name) (hash-ref x 'valueBoolean))))

;; bcse-libraries : -> (hash name (Result cql-library))   the measure's libraries, parsed
(define (bcse-libraries)
  (define b (call-with-input-file (build-path repo "BCSE_Details-2025.3.0.bundle.json") read-json))
    (for*/hash ([e (hash-ref b 'entry)] [r (in-value (hash-ref e 'resource))]
                #:when (equal? (hash-ref r 'resourceType) "Library")
                [c (hash-ref r 'content '())] #:when (equal? (hash-ref c 'contentType #f) "text/cql"))
      (values (hash-ref r 'name)
              (parse-cql (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref c 'data))))))))

;; library-resolver : (hash name Result) -> (name version -> (or cql-library #f))   the compiler names
;; an included library by a symbol
(define ((library-resolver parsed) name version)
  (let ([p (hash-ref parsed (format "~a" name) #f)]) (and p (ok? p) (ok-value p))))

;; libraries-compiling : (hash name Result) -> (values Natural Natural)   those that compile, of all
(define (libraries-compiling parsed)
  (define resolver (library-resolver parsed))
  (define clean
    (parameterize ([current-library-resolver resolver])
      (for/sum ([(n p) parsed])
        (if (and (ok? p)
                 (let-values ([(lib errs) (with-handlers ([exn:fail? (lambda (_) (values #f '(crash)))])
                                            (compile-library/errors (ok-value p)))])
                   (and lib (null? errs))))
            1 0))))
  (values clean (hash-count parsed)))

;; evaluate-scenario : (hash name Result) (listof resource) (listof ValueSet) -> (hash name Boolean)
;; BCSE_Details's population defines over the scenario's resources (null as false)
(define (evaluate-scenario parsed resources valuesets)
  (define rl (load-runtime-library (ok-value (hash-ref parsed "BCSE_Details"))
                                   #:resolver (library-resolver parsed)
                                   #:data (resources->data resources)
                                   #:valuesets (valuesets->terminology valuesets)))
  (for/hash ([n population-names])
    (values n (let ([v (with-handlers ([exn:fail? (lambda (e) (list 'error (exn-message e)))]) (rlib-value rl n))])
                (cond [(eq? v #t) #t] [(or (eq? v #f) (cql-null? v)) #f] [else v])))))

;; the scenarios on which the interpreter agrees with every scorekey value; only rises
(define agreement-floor 19)

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
   (define parsed (bcse-libraries))
   (define-values (clean total) (libraries-compiling parsed))
   (cond
     [(< clean total)
      (printf "BCS-E evaluation: PENDING, ~a/~a of the measure's libraries compile (needs cql with the parser fixes, 2b846aa)\n" clean total)]
     [else
      (define valuesets (filter (lambda (a) (equal? (hash-ref a 'resourceType) "ValueSet")) artifacts))
      (define results
        (for/list ([b (sort bundles string<? #:key (lambda (b) (hash-ref b 'id)))])
          (define id (hash-ref b 'id))
          (define resources (for*/list ([e (hash-ref b 'entry '())] [r (in-value (hash-ref e 'resource #f))]
                                        #:when (and r (not (equal? (hash-ref r 'resourceType) "Parameters"))))
                              r))
          (define expected (scorekey-values (hash-ref by-id (cons "Parameters" (string-append id ".scorekey")))))
          (define got (evaluate-scenario parsed resources valuesets))
          (define wrong (for/list ([n population-names] #:unless (equal? (hash-ref got n) (hash-ref expected n)))
                          (list n (hash-ref expected n) (hash-ref got n))))
          (cons id wrong)))
      (define agree (count (lambda (r) (null? (cdr r))) results))
      (printf "BCS-E evaluation: the interpreter agrees with ~a/~a scenario scorekeys\n" agree (length results))
      (for ([r results] #:when (pair? (cdr r)))
        (printf "  ~a:~a\n" (car r)
                (apply string-append (for/list ([w (cdr r)]) (format " ~a expected ~a got ~a;" (car w) (cadr w) (caddr w))))))
      (check-true (>= agree agreement-floor) (format "fewer scenarios agree than the floor ~a" agreement-floor))])])
