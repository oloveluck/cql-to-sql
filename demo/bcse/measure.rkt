#lang racket/base

;;; measure.rkt — NCQA's BCS-E measure (BCSE_Details 2025.3.0), as the two BCS-E demos run it: the
;;; scenario members (run.rkt) and the n=1000 test population (population.rkt).
;;;
;;; A Defines is (hash define-name Boolean): the measure's population defines for one member, null
;;; read as false.
;;;
;;; MeasureReports follow FHIR's population rules: the denominator holds the eligible members, the
;;; exclusions are a subset of it, subtracted for the score. NCQA's "Denominator" define already
;;; leaves the excluded out, so counting the Measure's own criteria the FHIR way would report no
;;; exclusions at all (with the same score); the counts here take the exclusions from the
;;; "Exclusion" defines instead.

(require racket/contract racket/list json net/base64
         (only-in fhir/result/result ok? ok-value)
         (only-in cql/parser/parse parse-cql)
         (only-in cql/compile compile-library/errors current-library-resolver)
         (only-in cql/run load-runtime-library resources->data rlib-value)
         racket/runtime-path)

(provide
 period-start period-end population-names
 (contract-out
  [measure-libraries (-> hash?)]
  [compiling-count (-> hash? exact-nonnegative-integer?)]
  [bcse-measure (-> hash?)]
  [measure-resources (-> (listof hash?))]
  [library-text (-> string? (or/c #f string?))]
  [member-library (-> hash? procedure? (listof hash?) any/c)]
  [library-defines (-> any/c hash?)]
  [evaluate-defines (-> hash? procedure? (listof hash?) hash?)]
  [group-counts (-> hash? string? string? hash?)]
  [member-counts (-> hash? (listof hash?))]
  [sum-counts (-> (listof hash?) hash?)]))

(define-runtime-path repo "../..")
(define details-bundle (build-path repo "BCSE_Details-2025.3.0.bundle.json"))

(define period-start "2025-01-01")
(define period-end "2025-12-31")

(define population-names
  '("Initial population" "Exclusion" "Denominator" "Numerator" "Exclusion - Medicare" "Denominator - Medicare"))

(define (bundle-resources) (for/list ([e (hash-ref (call-with-input-file details-bundle read-json) 'entry)]) (hash-ref e 'resource)))

;; bcse-measure : -> Measure
(define (bcse-measure) (findf (lambda (r) (equal? (hash-ref r 'resourceType) "Measure")) (bundle-resources)))

;; measure-resources : -> (listof resource)   the Measure and its 43 Libraries, as a FHIR server holds them
(define (measure-resources)
  (filter (lambda (r) (member (hash-ref r 'resourceType) '("Measure" "Library"))) (bundle-resources)))

;; measure-libraries : -> (hash name (Result cql-library))   the bundle's CQL, parsed
(define (measure-libraries)
  (for*/hash ([r (bundle-resources)] #:when (equal? (hash-ref r 'resourceType) "Library")
              [c (hash-ref r 'content '())] #:when (equal? (hash-ref c 'contentType #f) "text/cql"))
    (values (hash-ref r 'name)
            (parse-cql (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref c 'data))))))))

;; the compiler names an included library by a symbol
(define ((library-resolver parsed) name _version)
  (let ([p (hash-ref parsed (format "~a" name) #f)]) (and p (ok? p) (ok-value p))))

;; compiling-count : (hash name Result) -> Natural   the libraries that compile without errors
(define (compiling-count parsed)
  (parameterize ([current-library-resolver (library-resolver parsed)])
    (for/sum ([(_n p) parsed])
      (define-values (lib errs)
        (if (ok? p)
            (with-handlers ([exn:fail? (lambda (_) (values #f '(crash)))]) (compile-library/errors (ok-value p)))
            (values #f '(parse))))
      (if (and lib (null? errs)) 1 0))))

;; library-text : String -> String   a library's CQL, as the bundle carries it
(define (library-text name)
  (for*/first ([r (bundle-resources)] #:when (equal? (hash-ref r 'name #f) name)
               [c (hash-ref r 'content '())] #:when (equal? (hash-ref c 'contentType #f) "text/cql"))
    (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref c 'data))))))

;; member-library : (hash name Result) terminology (listof resource) -> rlib   BCSE_Details over one
;; member's records (and any shared resources), with its default measurement period
(define (member-library parsed terminology resources)
  (load-runtime-library (ok-value (hash-ref parsed "BCSE_Details"))
                        #:resolver (library-resolver parsed)
                        #:data (resources->data resources)
                        #:valuesets terminology))

;; library-defines : rlib -> Defines
(define (library-defines rl) (for/hash ([n population-names]) (values n (eq? (rlib-value rl n) #t))))

;; evaluate-defines : (hash name Result) terminology (listof resource) -> Defines
(define (evaluate-defines parsed terminology resources)
  (library-defines (member-library parsed terminology resources)))

;; group-counts : Defines String String -> (hash population-code 0|1)   one member in one group
(define (group-counts d exclusion denominator)
  (define ip (hash-ref d "Initial population"))
  (define excl (and ip (hash-ref d exclusion)))
  (define num (and ip (hash-ref d denominator) (hash-ref d "Numerator")))
  (define (n b) (if b 1 0))
  (hash "initial-population" (n ip) "denominator" (n ip) "denominator-exclusion" (n excl) "numerator" (n num)))

;; member-counts : Defines -> (list all-members-counts medicare-counts)
(define (member-counts d)
  (list (group-counts d "Exclusion" "Denominator") (group-counts d "Exclusion - Medicare" "Denominator - Medicare")))

(define (sum-counts hs) (for/fold ([acc (hash)]) ([h hs]) (for/fold ([a acc]) ([(k v) h]) (hash-update a k (lambda (x) (+ x v)) 0))))
