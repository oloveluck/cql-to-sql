#lang racket/base

;;; run.rkt — the BCS-E demo: NCQA's Breast Cancer Screening measure (HEDIS MY2025), unmodified,
;;; evaluated over the 19 scenario members, as a funnel table and as FHIR MeasureReports.
;;;
;;;   racket demo/bcse/run.rkt      prints the table, writes demo/out/bcse/*.json
;;;
;;; For each member, the measure's own CQL (BCSE_Details and the 42 libraries it includes) is run by
;;; the cql interpreter over the member's records, with the stand-in value sets and measurement year
;;; 2025; its population defines place the member in the funnel: eligible (Initial population),
;;; excused (Exclusion), accountable (Denominator), screened (Numerator). The same for the Medicare
;;; reporting group, which excuses long-term-care members too.
;;;
;;; The MeasureReports are built by cql/measure's `measure-report` from those defines, with FHIR's
;;; population rules: the denominator holds the eligible members and the exclusions are a subset of
;;; it, subtracted for the score. (NCQA's "Denominator" define already leaves the excluded out, so
;;; counting the Measure's own criteria the FHIR way reports no exclusions at all; the score is the
;;; same either way.)
;;;
;;; Needs: `racket scripts/install-hedis.rkt` (the HEDIS packages for fsh) and a cql that compiles
;;; NCQA's libraries (upstream 5b4e5b2 or later). With an older cql it says so and stops.

(require racket/contract racket/file racket/format racket/list racket/runtime-path racket/string
         json net/base64
         (only-in fsh/check check-report-artifacts check-report-examples check-report-invalid)
         (only-in fhir/result/result ok? ok-value)
         (only-in cql/parser/parse parse-cql)
         (only-in cql/compile compile-library/errors current-library-resolver)
         (only-in cql/run load-runtime-library resources->data valuesets->terminology rlib-value)
         (only-in cql/measure measure-report)
         "../../scripts/bcse-check.rkt")

(provide
 (contract-out
  [run-bcse (-> (or/c #f (listof member-result?)))]))   ; #f when the cql cannot compile BCS-E

(define-runtime-path repo "../..")
(define-runtime-path out-dir "../out/bcse")

(define period-start "2025-01-01")
(define period-end "2025-12-31")

;; A MemberResult is (member-result id story patient-id defines expected)
;;   defines, expected : (hash define-name Boolean)   the interpreter's and the score key's
(struct member-result (id story patient defines expected) #:transparent)

(define population-names
  '("Initial population" "Exclusion" "Denominator" "Numerator" "Exclusion - Medicare" "Denominator - Medicare"))

;; ---- the measure ------------------------------------------------------------------------------
(define details-bundle (build-path repo "BCSE_Details-2025.3.0.bundle.json"))

(define (bundle-resources f) (for/list ([e (hash-ref (call-with-input-file f read-json) 'entry)]) (hash-ref e 'resource)))

;; measure-libraries : -> (hash name (Result cql-library))   the bundle's CQL, parsed
(define (measure-libraries)
  (for*/hash ([r (bundle-resources details-bundle)] #:when (equal? (hash-ref r 'resourceType) "Library")
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

;; ---- the members ------------------------------------------------------------------------------
;; stories : -> (hash bundle-id String)   each scenario Bundle's FSH Title, "BCS-E NN: " dropped
(define (stories)
  (for*/hash ([f (directory-list (build-path repo "scenarios" "bcse" "input" "fsh") #:build? #t)]
              #:when (regexp-match? #rx"bcse-[0-9]+-.*[.]fsh$" (path->string f))
              [m (in-value (regexp-match #px"Instance: (bcse-[0-9]+)\nInstanceOf: Bundle\nUsage: #example\nTitle: \"BCS-E [0-9]+: ([^\"]*)\""
                                         (file->string f)))]
              #:when m)
    (values (cadr m) (caddr m))))

(define (truthy v) (eq? v #t))   ; null counts as false

;; run-bcse : -> (or #f (listof MemberResult))
(define (run-bcse)
  (define parsed (measure-libraries))
  (define clean (compiling-count parsed))
  (cond
    [(< clean (hash-count parsed))
     (printf "Only ~a of the measure's ~a CQL libraries compile with this cql; the demo needs cql upstream 5b4e5b2 or later.\n"
             clean (hash-count parsed))
     (printf "With an up-to-date cql checkout elsewhere: racket -S <its parent directory> demo/bcse/run.rkt\n")
     #f]
    [else
     (define report (check-scenarios))
     (printf "Member records: ~a FHIR resources checked against NCQA's HEDIS profiles, ~a invalid.\n\n"
             (check-report-examples report) (check-report-invalid report))
     (define artifacts (check-report-artifacts report))
     (define (of-type t) (filter (lambda (a) (equal? (hash-ref a 'resourceType) t)) artifacts))
     (define terminology (valuesets->terminology (of-type "ValueSet")))
     (define by-id (for/hash ([a artifacts]) (values (cons (hash-ref a 'resourceType) (hash-ref a 'id)) a)))
     (define titles (stories))
     (for/list ([b (sort (filter (lambda (b) (regexp-match? #rx"^bcse-[0-9]+$" (hash-ref b 'id))) (of-type "Bundle"))
                         string<? #:key (lambda (b) (hash-ref b 'id)))])
       (define id (hash-ref b 'id))
       (define resources (for*/list ([e (hash-ref b 'entry '())] [r (in-value (hash-ref e 'resource #f))]
                                     #:when (and r (not (equal? (hash-ref r 'resourceType) "Parameters"))))
                           r))
       (define patient (hash-ref (findf (lambda (r) (equal? (hash-ref r 'resourceType) "Patient")) resources) 'id))
       (define rl (load-runtime-library (ok-value (hash-ref parsed "BCSE_Details"))
                                        #:resolver (library-resolver parsed)
                                        #:data (resources->data resources)
                                        #:valuesets terminology))
       (define key (hash-ref by-id (cons "Parameters" (string-append id ".scorekey"))))
       (member-result id (hash-ref titles id id) patient
                      (for/hash ([n population-names]) (values n (truthy (rlib-value rl n))))
                      (for/hash ([p (hash-ref key 'parameter)]) (values (hash-ref p 'name) (hash-ref p 'valueBoolean)))))]))

;; ---- MeasureReports ---------------------------------------------------------------------------
;; group-counts : MemberResult String String -> (hash population-code 0|1)   one member in one group,
;; by FHIR's rules: exclusions within the denominator, the numerator within what is left
(define (group-counts r exclusion denominator)
  (define d (member-result-defines r))
  (define ip (hash-ref d "Initial population"))
  (define excl (and ip (hash-ref d exclusion)))
  (define num (and ip (hash-ref d denominator) (hash-ref d "Numerator")))
  (define (n b) (if b 1 0))
  (hash "initial-population" (n ip) "denominator" (n ip) "denominator-exclusion" (n excl) "numerator" (n num)))

(define (member-counts r)
  (list (group-counts r "Exclusion" "Denominator") (group-counts r "Exclusion - Medicare" "Denominator - Medicare")))

(define (sum-counts hs) (for/fold ([acc (hash)]) ([h hs]) (for/fold ([a acc]) ([(k v) h]) (hash-update a k (lambda (x) (+ x v)) 0))))

;; write-reports! : (listof MemberResult) -> Path   an individual report per member and the summary
(define (write-reports! results)
  (define measure (findf (lambda (r) (equal? (hash-ref r 'resourceType) "Measure")) (bundle-resources details-bundle)))
  (make-directory* out-dir)
  (define (save! name js) (call-with-output-file (build-path out-dir name) #:exists 'replace (lambda (o) (write-json js o))))
  (for ([r results])
    (save! (format "~a.json" (member-result-id r))
           (measure-report measure (member-counts r) period-start period-end (string-append "Patient/" (member-result-patient r)))))
  (define per-member (map member-counts results))
  (save! "summary.json" (measure-report measure (list (sum-counts (map car per-member)) (sum-counts (map cadr per-member)))
                                        period-start period-end #f))
  (simplify-path out-dir))

;; ---- the table --------------------------------------------------------------------------------
(define (outcome r exclusion denominator)
  (define d (member-result-defines r))
  (cond [(not (hash-ref d "Initial population")) "not eligible"]
        [(hash-ref d exclusion) "excused"]
        [(and (hash-ref d denominator) (hash-ref d "Numerator")) "screened"]
        [else "not screened"]))

(define (print-table results)
  (define (yes b) (if b "yes" "-"))
  (printf "~a  ~a  ~a  ~a  ~a  ~a\n" (~a "#" #:width 3) (~a "member" #:width 62)
          (~a "eligible" #:width 8) (~a "excused" #:width 7) (~a "screened" #:width 8) "outcome")
  (for ([r results])
    (define d (member-result-defines r))
    (define all (outcome r "Exclusion" "Denominator"))
    (define medicare (outcome r "Exclusion - Medicare" "Denominator - Medicare"))
    (printf "~a  ~a  ~a  ~a  ~a  ~a~a\n"
            (~a (substring (member-result-id r) 5) #:width 3)
            (~a (member-result-story r) #:width 62 #:limit-marker "…")
            (~a (yes (hash-ref d "Initial population")) #:width 8)
            (~a (yes (hash-ref d "Exclusion")) #:width 7)
            (~a (yes (and (hash-ref d "Denominator") (hash-ref d "Numerator"))) #:width 8)
            all
            (if (equal? all medicare) "" (format " (Medicare group: ~a)" medicare)))))

(define (print-totals results)
  (printf "\n~a  ~a  ~a  ~a  ~a  ~a\n" (~a "" #:width 26) (~a "eligible" #:width 8 #:align 'right) (~a "excused" #:width 7 #:align 'right)
          (~a "accountable" #:width 11 #:align 'right) (~a "screened" #:width 8 #:align 'right) "rate")
  (for ([g (list (list "All members" "Exclusion" "Denominator")
                 (list "Medicare reporting group" "Exclusion - Medicare" "Denominator - Medicare"))])
    (define c (sum-counts (for/list ([r results]) (group-counts r (cadr g) (caddr g)))))
    (define accountable (- (hash-ref c "denominator") (hash-ref c "denominator-exclusion")))
    (define (n k) (~a (hash-ref c k) #:width 8 #:align 'right))
    (printf "~a  ~a  ~a  ~a  ~a  ~a\n" (~a (car g) #:width 26) (n "initial-population")
            (~a (hash-ref c "denominator-exclusion") #:width 7 #:align 'right) (~a accountable #:width 11 #:align 'right)
            (n "numerator")
            (if (zero? accountable) "-" (string-append (~r (* 100 (/ (hash-ref c "numerator") accountable)) #:precision (quote (= 1))) "%")))))

;; agreeing : (listof MemberResult) -> (listof MemberResult)   those matching their expected result
(define (agreeing results)
  (filter (lambda (r) (for/and ([n population-names]) (equal? (hash-ref (member-result-defines r) n)
                                                              (hash-ref (member-result-expected r) n))))
          results))

(module+ main
  (printf "Breast Cancer Screening (NCQA HEDIS BCS-E), measurement year 2025, over ~a test members\n\n" 19)
  (define results (run-bcse))
  (when results
    (print-table results)
    (print-totals results)
    (printf "\nThe measure's result matches the expected result for ~a of ~a members.\n" (length (agreeing results)) (length results))
    (printf "FHIR MeasureReports (one per member, and the summary): ~a\n" (write-reports! results))
    (printf "\nTest data: synthetic members and TEST-ONLY stand-in code lists, not NCQA's; the rate is not a HEDIS rate.\n")))

(module+ test
  (require rackunit)
  (define results (if (file-exists? (build-path repo "vendor" "packages" "ncqa.hedis.core.main.v2025-2025.1.0.tgz")) (run-bcse) #f))
  (when results
    (check-equal? (length (agreeing results)) (length results) "every member's result matches the score key")
    (define c (sum-counts (map (lambda (r) (car (member-counts r))) results)))
    (check-equal? (list (hash-ref c "initial-population") (hash-ref c "denominator-exclusion") (hash-ref c "numerator"))
                  '(14 5 4))))
