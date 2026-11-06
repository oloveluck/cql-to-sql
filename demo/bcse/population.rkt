#lang racket/base

;;; population.rkt — NCQA's BCS-E measure over a synthetic population of 1,000 members, compared with
;;; the population's own answer key.
;;;
;;;   racket demo/bcse/population.rkt     prints the funnel, the comparison and every difference with
;;;                                        its cause; writes demo/out/bcse-population/*.json
;;;
;;; The population is `bcse_usqc_testdata_n1000.zip` (repo root): a FHIR Bulk Data export, one NDJSON
;;; file per resource type, on the US Quality Core 0.5.0 profiles, with `answer_key_bcse_my2025.csv`,
;;; the expected populations per member from the generator's scenario design (not from a measure
;;; engine). It is read straight from the zip.
;;;
;;; The adapter. NCQA's CQL reads enrollment the way HEDIS data carries it; this export carries it the
;;; US Quality Core way, so before evaluation each Coverage is mapped as a health plan's HEDIS load
;;; would (nothing else is changed):
;;; - its NAHDO payer type (SOPT 5 private, 1 Medicare, 2 Medicaid) also gets the HEDIS coverage type
;;;   (PPO, MCR, MCD) and the medical benefit (ActCode HIP): NCQA finds the product line through a
;;;   fixed matrix of HEDIS coverage-type codes, so no value set can stand in for it;
;;; - an open period (no end: still enrolled) ends on the export's date. NCQA builds
;;;   Interval[start, end] directly, and in CQL a closed interval with a null end has an UNKNOWN
;;;   end, so open coverage would never show continuous enrollment.
;;;
;;; The comparison. A member agrees when all four populations match the key: eligible (NCQA's
;;; Initial population, which includes continuous enrollment: the key's denominator_eligible),
;;; excused, accountable, screened (within the accountable). Every disagreement is assigned a cause
;;; from `causes` below; each was traced through the measure's CQL. Any disagreement without one is
;;; printed as unexplained, and the test fails on it.

(require racket/contract racket/file racket/format racket/list racket/port racket/runtime-path racket/string
         json file/unzip
         (only-in fsh/check check-report-artifacts)
         (only-in cql/run valuesets->terminology)
         (only-in cql/measure measure-report)
         "../../scripts/bcse-check.rkt"
         "measure.rkt")

(provide
 (contract-out
  [run-population (-> (or/c #f (listof person?)))]))   ; #f when the cql cannot compile BCS-E

(define-runtime-path repo "../..")
(define-runtime-path out-dir "../out/bcse-population")
(define population-zip (build-path repo "bcse_usqc_testdata_n1000.zip"))

;; A Person is (person id key defines resources)
;;   key : (hash column String)   its answer-key row
;;   defines : Defines            the measure's populations for it
;;   resources : (listof resource) its records, after the adapter
(struct person (id key defines resources) #:transparent)

;; ---- reading the export -----------------------------------------------------------------------
;; zip-entries : Path -> (hash name bytes)
(define (zip-entries zip)
  (define entries (make-hash))
  (call-with-input-file zip
    (lambda (in) (unzip in (lambda (name dir? content) (unless dir? (hash-set! entries (bytes->string/utf-8 name) (port->bytes content)))))))
  entries)

(define (entry entries suffix)
  (for/first ([(n b) entries] #:when (string-suffix? n suffix)) b))

(define shared-types '("Organization" "Location" "Practitioner" "PractitionerRole" "Medication" "Substance"))

;; references : jsexpr -> (listof String)   every Reference.reference inside
(define (references js)
  (cond [(hash? js) (append* (for/list ([(k v) js]) (if (and (eq? k 'reference) (string? v)) (list v) (references v))))]
        [(list? js) (append* (map references js))]
        [else '()]))

;; ---- the adapter ------------------------------------------------------------------------------
(define sopt "https://nahdo.org/sopt")
(define sopt->hedis (hash "5" '("PPO" "Commercial PPO") "1" '("MCR" "Medicare Advantage HMO") "2" '("MCD" "Medicaid")))

;; hedis-coverage : String -> resource -> resource   a Coverage as HEDIS carries it; others unchanged
(define ((hedis-coverage export-date) r)
  (cond
    [(equal? (hash-ref r 'resourceType) "Coverage")
     (define type (hash-ref r 'type (hasheq)))
     (define codings (hash-ref type 'coding '()))
     (define added
       (append*
        (for/list ([c codings] #:when (equal? (hash-ref c 'system #f) sopt))
          (define h (hash-ref sopt->hedis (hash-ref c 'code) #f))
          (if h
              (list (hasheq 'system "https://ncqa.org/fhir/CodeSystem/hedis-coverage-type" 'code (car h) 'display (cadr h))
                    (hasheq 'system "http://terminology.hl7.org/CodeSystem/v3-ActCode" 'code "HIP" 'display "health insurance plan policy"))
              '()))))
     (define period (hash-ref r 'period (hasheq)))
     (let ([r (hash-set r 'type (hash-set type 'coding (append codings added)))])
       (if (hash-has-key? period 'end) r (hash-set r 'period (hash-set period 'end export-date))))]
    [else r]))

;; ---- the answer key ---------------------------------------------------------------------------
;; csv-rows : String -> (listof (hash column String))   quoted fields may hold commas
(define (csv-rows text)
  (define lines (filter (lambda (l) (not (equal? (string-trim l) ""))) (string-split text "\n")))
  (define (fields l) (for/list ([f (regexp-match* #px"(\"[^\"]*\"|[^,]*)(?:,|$)" (string-trim l "\r" #:left? #f) #:match-select cadr)])
                       (string-trim f "\"")))
  (define header (fields (car lines)))
  (for/list ([l (cdr lines)]) (for/hash ([h header] [v (fields l)]) (values h v))))

;; ---- running ----------------------------------------------------------------------------------
(define (run-population)
  (define parsed (measure-libraries))
  (define clean (compiling-count parsed))
  (cond
    [(< clean (hash-count parsed))
     (printf "Only ~a of the measure's ~a CQL libraries compile with this cql; the demo needs cql upstream 29b6bf8 or later.\n"
             clean (hash-count parsed))
     #f]
    [else
     (define entries (zip-entries population-zip))
     (define export-date (substring (hash-ref (bytes->jsexpr (entry entries "bulk/manifest.json")) 'transactionTime) 0 10))
     (define adapt (hedis-coverage export-date))
     (define by-patient (make-hash))
     (define shared '())
     (for ([(name bytes) entries] #:when (regexp-match? #rx"bulk/[A-Za-z]+[.]ndjson$" name))
       (for ([line (string-split (bytes->string/utf-8 bytes) "\n")] #:unless (equal? (string-trim line) ""))
         (define r (adapt (string->jsexpr line)))
         (define t (hash-ref r 'resourceType))
         (cond [(member t shared-types) (set! shared (cons r shared))]
               [(equal? t "Patient") (hash-update! by-patient (hash-ref r 'id) (lambda (l) (cons r l)) '())]
               [else (for ([p (remove-duplicates (filter-map (lambda (s) (let ([m (regexp-match #rx"^Patient/(.+)$" s)]) (and m (cadr m))))
                                                              (references r)))])
                       (hash-update! by-patient p (lambda (l) (cons r l)) '()))])))
     (define terminology
       (valuesets->terminology (filter (lambda (a) (equal? (hash-ref a 'resourceType) "ValueSet")) (check-report-artifacts (check-scenarios)))))
     (for/list ([k (csv-rows (bytes->string/utf-8 (entry entries "answer_key_bcse_my2025.csv")))])
       (define id (hash-ref k "patient_id"))
       (define rs (hash-ref by-patient id '()))
       (person id k (evaluate-defines parsed terminology (append rs shared)) rs))]))

;; ---- comparing --------------------------------------------------------------------------------
;; the four populations, as the measure has them and as the key does
(define (ours m)
  (define d (person-defines m))
  (define ip (hash-ref d "Initial population"))
  (hash 'eligible ip 'excused (and ip (hash-ref d "Exclusion")) 'accountable (hash-ref d "Denominator")
        'screened (and (hash-ref d "Denominator") (hash-ref d "Numerator"))))
(define (theirs m)
  (define (yes c) (equal? (hash-ref (person-key m) c) "1"))
  (hash 'eligible (yes "denominator_eligible") 'excused (yes "excluded") 'accountable (yes "denominator") 'screened (yes "numerator")))
(define (differs m) (filter (lambda (p) (not (eq? (hash-ref (ours m) p) (hash-ref (theirs m) p)))) '(eligible excused accountable screened)))

;; codes the export uses for a mammogram (the stand-in Mammography value set)
(define mammography-codes '("77067" "77066" "77065" "77063" "24606-6"))
(define (coded? r codes) (for/or ([c (in-list codes)]) (regexp-match? (regexp (string-append "\"code\":\"" (regexp-quote c) "\"")) (jsexpr->string r))))
(define (of-type m t) (filter (lambda (r) (equal? (hash-ref r 'resourceType) t)) (person-resources m)))

;; A Cause is (cause label explanation matches?), matches? : Member -> Boolean
(struct cause (label explanation matches?))
(define (edge . ids) (lambda (m) (and (member (hash-ref (person-key m) "edge_case") ids) #t)))

(define causes
  (list
   (cause "mammogram only as a Procedure"
          "NCQA's numerator reads mammograms from claims, EOBs, Observations and DiagnosticReports, not from Procedure; this export records most screenings as a Procedure (the eCQM convention)"
          (lambda (m) (and (equal? (differs m) '(screened))
                           (for/or ([r (of-type m "Procedure")]) (coded? r mammography-codes))
                           (not (for/or ([t '("Claim" "DiagnosticReport" "Observation")])
                                  (for/or ([r (of-type m t)]) (coded? r mammography-codes)))))))
   (cause "key ignores its own sex-at-birth record"
          "the member's gender is unknown but a final sex-assigned-at-birth Observation says female, which the key's stated rule counts; the key leaves it out"
          (lambda (m) (and (equal? (hash-ref (person-key m) "sex_assigned_at_birth") "")
                           (for/or ([r (of-type m "Observation")]) (and (coded? r '("76689-9")) (coded? r '("LA3-6")))))))
   (cause "key: two unilateral mastectomies 14+ days apart"
          "the key excludes two unilateral mastectomies without laterality; MY2025 BCS-E has no such rule (bilateral modifier, left plus right, history or absence of both breasts)"
          (edge "EXC-06"))
   (cause "key: frailty on one date"
          "NCQA's frailty needs indications on at least two dates in the measurement year; the member has one"
          (edge "EXC-16"))
   (cause "measure ignores Coverage.status"
          "a cancelled coverage still counts as enrollment: NCQA's logic reads the period, not the status"
          (edge "ENR-05"))
   (cause "measure ignores Condition.verificationStatus"
          "a refuted history of bilateral mastectomy still excludes: NCQA's logic does not read verification status"
          (edge "EXC-10"))
   (cause "measure does not read ServiceRequest"
          "hospice recorded only as a ServiceRequest is not hospice to NCQA's logic"
          (edge "EXC-13"))
   (cause "cql: Quantity.value / .unit are null"
          "the interpreter returns null for (45 days).value and .unit, so an allowed coverage gap fails continuous enrollment (a cql bug)"
          (edge "ENR-01"))))

;; explain : Member -> (or Cause #f)
(define (explain m) (for/first ([c causes] #:when ((cause-matches? c) m)) c))

;; ---- reporting --------------------------------------------------------------------------------
(define (count-of ms p f) (count (lambda (m) (hash-ref (f m) p)) ms))
(define (pct n d) (if (zero? d) "-" (string-append (~r (* 100 (/ n d)) #:precision '(= 1)) "%")))

(define (print-funnel ms)
  (define (col s) (~a s #:width 12 #:align 'right))
  (printf "~a~a~a\n" (~a "" #:width 34) (col "NCQA logic") (col "answer key"))
  (for ([row (list (list "members" (lambda (f) (length ms)))
                   (list "eligible (initial population)" (lambda (f) (count-of ms 'eligible f)))
                   (list "excused (exclusions)" (lambda (f) (count-of ms 'excused f)))
                   (list "accountable (denominator)" (lambda (f) (count-of ms 'accountable f)))
                   (list "screened (numerator)" (lambda (f) (count-of ms 'screened f)))
                   (list "rate" (lambda (f) (pct (count-of ms 'screened f) (count-of ms 'accountable f)))))])
    (printf "~a~a~a\n" (~a (car row) #:width 34) (col ((cadr row) ours)) (col ((cadr row) theirs)))))

(define (print-differences ms)
  (define differing (filter (lambda (m) (pair? (differs m))) ms))
  (printf "\nThe measure agrees with the answer key on ~a of ~a members. The ~a others, by cause:\n"
          (- (length ms) (length differing)) (length ms) (length differing))
  (for ([c causes])
    (define these (filter (lambda (m) (eq? (explain m) c)) differing))
    (unless (null? these)
      (printf "\n  ~a  ~a\n     ~a\n     e.g. ~a\n" (~a (length these) #:width 4 #:align 'right) (cause-label c) (cause-explanation c)
              (string-join (map person-id (take these (min 3 (length these)))) ", "))))
  (define unexplained (filter (lambda (m) (not (explain m))) differing))
  (unless (null? unexplained)
    (printf "\n  ~a  UNEXPLAINED: ~a\n" (~a (length unexplained) #:width 4 #:align 'right)
            (string-join (for/list ([m (take unexplained (min 10 (length unexplained)))]) (format "~a ~a" (person-id m) (differs m))) "; "))))

;; write-reports! : (listof Member) -> Path   the summary MeasureReport, and every member's in one NDJSON
(define (write-reports! ms)
  (define measure (bcse-measure))
  (make-directory* out-dir)
  (define per-member (map (lambda (m) (member-counts (person-defines m))) ms))
  (call-with-output-file (build-path out-dir "summary.json") #:exists 'replace
    (lambda (o) (write-json (measure-report measure (list (sum-counts (map car per-member)) (sum-counts (map cadr per-member)))
                                            period-start period-end #f) o)))
  (call-with-output-file (build-path out-dir "individual.ndjson") #:exists 'replace
    (lambda (o) (for ([m ms] [c per-member])
                  (write-json (measure-report measure c period-start period-end (string-append "Patient/" (person-id m))) o)
                  (newline o))))
  (simplify-path out-dir))

(module+ main
  (printf "Breast Cancer Screening (NCQA HEDIS BCS-E), measurement year 2025, over a synthetic population\n\n")
  (define ms (run-population))
  (when ms
    (print-funnel ms)
    (print-differences ms)
    (printf "\nFHIR MeasureReports (the summary, and one per member): ~a\n" (write-reports! ms))
    (printf "\nTest data: synthetic members and TEST-ONLY stand-in code lists, not NCQA's; the rate is not a HEDIS rate.\n")))

(module+ test
  (require rackunit)
  (define ms (and (file-exists? (build-path repo "vendor" "packages" "ncqa.hedis.core.main.v2025-2025.1.0.tgz")) (run-population)))
  (when ms
    (check-equal? (length ms) 1000)
    (check-equal? (filter-map (lambda (m) (and (pair? (differs m)) (not (explain m)) (person-id m))) ms) '()
                  "every disagreement with the answer key has a known cause")
    (check-true (>= (count (lambda (m) (null? (differs m))) ms) 894) "fewer members agree than the floor")))
