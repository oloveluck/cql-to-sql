#lang racket/base

;;; hedis-population.rkt — NCQA's BCS-E over the HEDIS-shaped 1,000-member population.
;;;
;;;   racket demo/bcse/hedis-population.rkt          the funnel for both groups, where each screening and
;;;                                                  exclusion was found; writes demo/out/bcse-hedis/*.json
;;;
;;; `bcse_hedis_n1000_bulkfhir_aidbox_loaded.zip` (repo root) is a FHIR Bulk Data export of 1,000
;;; synthetic members recorded the way HEDIS data is: Coverage with NCQA's coverage types and benefits,
;;; the sex-for-clinical-use extension, mammograms on Claims and ExplanationOfBenefits (and a few
;;; Observations). Unlike the US Quality Core population (population.rkt), it needs no adapter, and it
;;; comes with no answer key: this reports what NCQA's logic computes, and the evidence behind it.

(require racket/contract racket/file racket/format racket/list racket/runtime-path racket/string json
         (only-in cql/run valuesets->terminology)
         (only-in cql/measure measure-report)
         "measure.rkt"
         "evidence.rkt"
         (only-in "population.rkt" zip-entries references shared-types measure-valuesets))

(provide
 (contract-out
  [run-hedis-population (-> (or/c #f (listof enrollee?)))]))

(define-runtime-path repo "../..")
(define-runtime-path out-dir "../out/bcse-hedis")
(define export-zip (build-path repo "bcse_hedis_n1000_bulkfhir_aidbox_loaded.zip"))

;; An Enrollee is (enrollee id defines evidence)
(struct enrollee (id defines evidence))

;; run-hedis-population : -> (or #f (listof Enrollee))   every Patient in the export, in id order
(define (run-hedis-population)
  (define parsed (measure-libraries))
  (cond
    [(< (compiling-count parsed) (hash-count parsed))
     (printf "The measure's libraries do not all compile with this cql; the demo needs cql upstream 29b6bf8 or later.\n")
     #f]
    [else
     (define entries (zip-entries export-zip))
     (define by-patient (make-hash))
     (define shared '())
     (for ([(name bytes) entries] #:when (regexp-match? #rx"[.]ndjson$" name))
       (for ([line (string-split (bytes->string/utf-8 bytes) "\n")] #:unless (equal? (string-trim line) ""))
         (define r (string->jsexpr line))
         (define t (hash-ref r 'resourceType))
         (cond [(memq-type t shared-types) (set! shared (cons r shared))]
               [(equal? t "Patient") (hash-update! by-patient (hash-ref r 'id) (lambda (l) (cons r l)) '())]
               [else (for ([p (remove-duplicates (filter-map (lambda (s) (let ([m (regexp-match #rx"^Patient/(.+)$" s)]) (and m (cadr m))))
                                                              (references r)))])
                       (hash-update! by-patient p (lambda (l) (cons r l)) '()))])))
     (define terminology (valuesets->terminology (measure-valuesets)))
     (define evidence (evidence-defines))
     (for/list ([id (sort (hash-keys by-patient) string<?)])
       (define rl (member-library parsed terminology (append (hash-ref by-patient id) shared)))
       (enrollee id (library-defines rl) (member-evidence rl evidence)))]))

(define (memq-type t types) (and (member t types) #t))

;; ---- reporting --------------------------------------------------------------------------------
(define groups '(("All members" "Exclusion" "Denominator") ("Medicare reporting group" "Exclusion - Medicare" "Denominator - Medicare")))

;; funnel : (listof Member) String String -> (values eligible excused accountable screened)
(define (funnel ms exclusion denominator)
  (define (n p) (count p ms))
  (define (d m k) (hash-ref (enrollee-defines m) k))
  (values (n (lambda (m) (d m "Initial population")))
          (n (lambda (m) (and (d m "Initial population") (d m exclusion))))
          (n (lambda (m) (d m denominator)))
          (n (lambda (m) (and (d m denominator) (d m "Numerator"))))))

(define (pct n d) (if (zero? d) "-" (string-append (~r (* 100 (/ n d)) #:precision '(= 1)) "%")))

(define (print-funnel ms)
  (define (col s) (~a s #:width 26 #:align 'right))
  (printf "~a~a\n" (~a "" #:width 32) (string-append* (map (lambda (g) (col (car g))) groups)))
  (define rows (for/list ([g groups]) (call-with-values (lambda () (funnel ms (cadr g) (caddr g))) list)))
  (for ([label '("eligible (initial population)" "excused (exclusions)" "accountable (denominator)" "screened (numerator)")] [i (in-naturals)])
    (printf "~a~a\n" (~a label #:width 32) (string-append* (map (lambda (r) (col (list-ref r i))) rows))))
  (printf "~a~a\n" (~a "rate" #:width 32) (string-append* (map (lambda (r) (col (pct (list-ref r 3) (list-ref r 2)))) rows))))

;; where : (listof Member) section (Member -> Boolean) -> (listof (cons define-name count))
;; for the members the predicate picks, how many had evidence under each define of the section
(define (where ms section pick)
  (define counts (make-hash))
  (for* ([m ms] #:when (pick m) [e (enrollee-evidence m)]
         #:when (and (equal? (hash-ref e 'section) section) (not (equal? (hash-ref e 'define) "Mammography screening period"))))
    (hash-update! counts (hash-ref e 'define) add1 0))
  (sort (hash->list counts) > #:key cdr))

(define (print-where ms)
  (define (d m k) (hash-ref (enrollee-defines m) k))
  (printf "\nWhere the screenings were found (accountable members screened; a member can have several):\n")
  (for ([p (where ms "screened" (lambda (m) (and (d m "Denominator") (d m "Numerator"))))])
    (printf "  ~a  ~a\n" (~a (cdr p) #:width 5 #:align 'right) (car p)))
  (printf "\nWhere the exclusions were found (eligible members excused):\n")
  (for ([p (where ms "excused" (lambda (m) (and (d m "Initial population") (d m "Exclusion"))))])
    (printf "  ~a  ~a\n" (~a (cdr p) #:width 5 #:align 'right) (car p))))

;; write-reports! : (listof Enrollee) -> Path   the summary MeasureReport, and every member's in one NDJSON
(define (write-reports! ms)
  (define measure (bcse-measure))
  (make-directory* out-dir)
  (define per-member (map (lambda (m) (member-counts (enrollee-defines m))) ms))
  (call-with-output-file (build-path out-dir "summary.json") #:exists 'replace
    (lambda (o) (write-json (measure-report measure (list (sum-counts (map car per-member)) (sum-counts (map cadr per-member)))
                                            period-start period-end #f) o)))
  (call-with-output-file (build-path out-dir "individual.ndjson") #:exists 'replace
    (lambda (o) (for ([m ms] [c per-member])
                  (write-json (measure-report measure c period-start period-end (string-append "Patient/" (enrollee-id m))) o)
                  (newline o))))
  (simplify-path out-dir))

(module+ main
  (printf "Breast Cancer Screening (NCQA HEDIS BCS-E), measurement year 2025, over the HEDIS-shaped population\n\n")
  (define ms (run-hedis-population))
  (when ms
    (printf "~a members\n\n" (length ms))
    (print-funnel ms)
    (print-where ms)
    (printf "\nFHIR MeasureReports (the summary, and one per member): ~a\n" (write-reports! ms))
    (printf "\nSynthetic members, NCQA's MY2025 value sets; no answer key came with this export.\n")))

(module+ test
  (require rackunit)
  (define ms (and (file-exists? export-zip) (file-exists? (build-path repo "vendor" "packages" "ncqa.hedis.core.main.v2025-2025.1.0.tgz"))
                  (run-hedis-population)))
  (when ms
    (check-equal? (length ms) 1000)
    ;; every screened member's screening is backed by a record
    (define (d m k) (hash-ref (enrollee-defines m) k))
    (check-equal? (filter (lambda (m) (and (d m "Denominator") (d m "Numerator")
                                           (null? (where (list m) "screened" (lambda (_) #t)))))
                          ms)
                  '() "every screened member has a mammography record")))
