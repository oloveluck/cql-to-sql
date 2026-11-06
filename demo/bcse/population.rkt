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
;;;   (PPO, MCR, MCD) and the medical benefit (ActCode MCPOL, in NCQA's Medical insurance set): NCQA finds the product line through a
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
         "../../scripts/ncqa-valuesets.rkt"
         "measure.rkt"
         "evidence.rkt")

(provide
 (contract-out
  [run-population (->* () (#:only (or/c #f (listof string?)) #:supplemental? boolean?) (or/c #f (listof person?)))]   ; #f when the cql cannot compile BCS-E
  [read-export (-> export?)]
  [export-resources (-> export? (listof hash?))]
  [measure-valuesets (-> (listof hash?))]
  [zip-entries (-> path-string? hash?)]
  [references (-> any/c (listof string?))]
  [shared-types (listof string?)]
  [person-id (-> person? string?)]
  [person-defines (-> person? hash?)]))

(define-runtime-path repo "../..")
(define-runtime-path out-dir "../out/bcse-population")
(define population-zip (build-path repo "bcse_usqc_testdata_n1000.zip"))

;; A Person is (person id key defines evidence resources)
;;   key : (hash column String)   its answer-key row
;;   defines : Defines            the measure's populations for it
;;   evidence : (listof Evidence)  the records behind them (evidence.rkt)
;;   resources : (listof resource) its records, after the adapter
(struct person (id key defines evidence resources) #:transparent)

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
                    (hasheq 'system "http://terminology.hl7.org/CodeSystem/v3-ActCode" 'code "MCPOL" 'display "managed care policy"))
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

;; ---- the export, read ---------------------------------------------------------------------------
;; An Export is (export resources by-patient shared key-rows)
;;   resources : (listof resource)              every resource, after the adapter
;;   by-patient : (hash patient-id (listof resource))   each member's records (any Patient/<id> reference)
;;   shared : (listof resource)                 the non-patient resources everyone may reference
;;   key-rows : (listof (hash column String))   the answer key
(struct export (resources by-patient shared key-rows))

;; read-export : -> Export   bcse_usqc_testdata_n1000.zip, through the adapter
(define (read-export)
  (define entries (zip-entries population-zip))
  (define export-date (substring (hash-ref (bytes->jsexpr (entry entries "bulk/manifest.json")) 'transactionTime) 0 10))
  (define adapt (hedis-coverage export-date))
  (define by-patient (make-hash))
  (define all '())
  (define shared '())
  (for ([(name bytes) entries] #:when (regexp-match? #rx"bulk/[A-Za-z]+[.]ndjson$" name))
    (for ([line (string-split (bytes->string/utf-8 bytes) "\n")] #:unless (equal? (string-trim line) ""))
      (define r (adapt (string->jsexpr line)))
      (define t (hash-ref r 'resourceType))
      (set! all (cons r all))
      (cond [(member t shared-types) (set! shared (cons r shared))]
            [(equal? t "Patient") (hash-update! by-patient (hash-ref r 'id) (lambda (l) (cons r l)) '())]
            [else (for ([p (remove-duplicates (filter-map (lambda (s) (let ([m (regexp-match #rx"^Patient/(.+)$" s)]) (and m (cadr m))))
                                                           (references r)))])
                    (hash-update! by-patient p (lambda (l) (cons r l)) '()))])))
  (export (reverse all) by-patient shared (csv-rows (bytes->string/utf-8 (entry entries "answer_key_bcse_my2025.csv")))))

;; measure-valuesets : -> (listof ValueSet)   NCQA's value sets BCS-E declares (scripts/ncqa-valuesets.rkt)
(define (measure-valuesets)
  (let-values ([(vss _source) (bcse-valuesets)]) vss))

;; ---- the what-if: the same records as a HEDIS supplemental data feed --------------------------------
;; NCQA's numerator reads mammograms from claims, EOBs, Observations and DiagnosticReports, never from
;; Procedure. A plan sending its clinical (EHR) data to HEDIS as supplemental data would send each
;; completed mammogram as a result. With #:supplemental?, every completed Procedure whose code is in
;; NCQA's Mammography value set ALSO appears as a final Observation: the same code, its effective time
;; the procedure's, derived from the procedure. A data transformation, labelled as such; the default
;; run reads the data as delivered.
(define (mammography-codes-set vss)
  (define v (findf (lambda (v) (regexp-match? #rx"[.]1004[.]1168$" (hash-ref v 'url ""))) vss))
  (for/hash ([c (if v (valueset-codes v) '())]) (values c #t)))

;; supplemental-observations : (listof resource) (hash (system . code) #t) -> (listof Observation)
(define (supplemental-observations rs mammography)
  (for/list ([r rs]
             #:when (and (equal? (hash-ref r 'resourceType) "Procedure") (equal? (hash-ref r 'status #f) "completed")
                         (for/or ([c (hash-ref (hash-ref r 'code (hasheq)) 'coding '())])
                           (hash-ref mammography (cons (hash-ref c 'system "") (hash-ref c 'code "")) #f))))
    (define base (hasheq 'resourceType "Observation" 'id (string-append "supplemental-" (hash-ref r 'id)) 'status "final"
                         'category (list (hasheq 'coding (list (hasheq 'system "http://terminology.hl7.org/CodeSystem/observation-category" 'code "procedure"))))
                         'code (hash-ref r 'code) 'subject (hash-ref r 'subject)
                         'derivedFrom (list (hasheq 'reference (string-append "Procedure/" (hash-ref r 'id))))))
    (cond [(hash-ref r 'performedDateTime #f) => (lambda (d) (hash-set base 'effectiveDateTime d))]
          [(hash-ref r 'performedPeriod #f) => (lambda (p) (hash-set base 'effectivePeriod p))]
          [else base])))

;; ---- running ----------------------------------------------------------------------------------
;; run-population : [#:only (or #f (listof id))] [#:supplemental? Boolean] -> (or #f (listof Person))
;; every member, or those named; with #:supplemental?, the what-if above
(define (run-population #:only [only #f] #:supplemental? [supplemental? #f])
  (define parsed (measure-libraries))
  (define clean (compiling-count parsed))
  (cond
    [(< clean (hash-count parsed))
     (printf "Only ~a of the measure's ~a CQL libraries compile with this cql; the demo needs cql upstream 29b6bf8 or later.\n"
             clean (hash-count parsed))
     #f]
    [else
     (define ex (read-export))
     (define vss (measure-valuesets))
     (define terminology (valuesets->terminology vss))
     (define mammography (mammography-codes-set vss))
     (define evidence (evidence-defines))
     (for/list ([k (export-key-rows ex)]
                #:when (or (not only) (member (hash-ref k "patient_id") only)))
       (define id (hash-ref k "patient_id"))
       (define delivered (hash-ref (export-by-patient ex) id '()))
       (define rs (if supplemental? (append delivered (supplemental-observations delivered mammography)) delivered))
       (define rl (member-library parsed terminology (append rs (export-shared ex))))
       (person id k (library-defines rl) (member-evidence rl evidence) rs))]))

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

;; the codes the export uses for a mammogram (all in NCQA's Mammography value set)
(define mammography-codes '("77067" "77066" "77065" "77063" "24606-6"))
(define (coded? r codes) (for/or ([c (in-list codes)]) (regexp-match? (regexp (string-append "\"code\":\"" (regexp-quote c) "\"")) (jsexpr->string r))))
(define (of-type m t) (filter (lambda (r) (equal? (hash-ref r 'resourceType) t)) (person-resources m)))

;; A Cause is (cause kind label explanation matches? records)
;;   kind : "data" | "key" | "measure" | "engine"   whose side the difference is on
;;   matches? : Person -> Boolean
;;   records : Person -> (listof String)   the member's records the difference turns on
(struct cause (kind label explanation matches? records))
(define (edge . ids) (lambda (m) (and (member (hash-ref (person-key m) "edge_case") ids) #t)))
;; lines : String (listof code) [resource -> String] -> Person -> (listof String)   records of a type with any of the codes
(define ((lines type codes [note (lambda (_r) "")]) m)
  (for/list ([r (of-type m type)] #:when (coded? r codes)) (string-append (resource-line r) (note r))))
(define (verification r)
  (let ([v (for*/first ([c (hash-ref (hash-ref r 'verificationStatus (hasheq)) 'coding '())]) (hash-ref c 'code #f))])
    (if v (format " (verification: ~a)" v) "")))
(define (coverages m) (map resource-line (of-type m "Coverage")))

(define causes
  (list
   (cause "data" "mammogram only as a Procedure"
          "NCQA's numerator reads mammograms from claims, EOBs, Observations and DiagnosticReports, not from Procedure; this export records most screenings as a Procedure (the eCQM convention)"
          (lambda (m) (and (equal? (differs m) '(screened))
                           (for/or ([r (of-type m "Procedure")]) (coded? r mammography-codes))
                           (not (for/or ([t '("Claim" "DiagnosticReport" "Observation")])
                                  (for/or ([r (of-type m t)]) (coded? r mammography-codes))))))
          (lines "Procedure" mammography-codes))
   (cause "key" "key ignores its own sex-at-birth record"
          "the member's gender is unknown but a final sex-assigned-at-birth Observation says female, which the key's stated rule counts; the key leaves it out"
          (lambda (m) (and (equal? (hash-ref (person-key m) "sex_assigned_at_birth") "")
                           (for/or ([r (of-type m "Observation")]) (and (coded? r '("76689-9")) (coded? r '("LA3-6"))))))
          (lines "Observation" '("76689-9") (lambda (_r) " = female (LA3-6)")))
   (cause "key" "key: two unilateral mastectomies 14+ days apart"
          "the key excludes two unilateral mastectomies without laterality; MY2025 BCS-E has no such rule (bilateral modifier, left plus right, history or absence of both breasts)"
          (edge "EXC-06")
          (lines "Procedure" '("19303")))
   (cause "data" "dysphoria coded F64.0, not in NCQA's set"
          "the gender-affirming surgery exclusion needs a gender dysphoria diagnosis; the data codes it F64.0, which NCQA's MY2025 Gender Dysphoria value set does not contain (it has F64.1, F64.2, F64.8, F64.9, Z87.890)"
          (edge "EXC-19")
          (lines "Condition" '("F64.0")))
   (cause "key" "key: frailty on one date"
          "NCQA's frailty needs indications on at least two dates in the measurement year; the member has one"
          (edge "EXC-16")
          (lines "Condition" '("R54")))
   (cause "measure" "measure ignores Coverage.status"
          "a cancelled coverage still counts as enrollment: NCQA's logic reads the period, not the status"
          (edge "ENR-05")
          coverages)
   (cause "measure" "measure ignores Condition.verificationStatus"
          "a refuted history of bilateral mastectomy still excludes: NCQA's logic does not read verification status"
          (edge "EXC-10")
          (lines "Condition" '("Z90.13") verification))
   (cause "measure" "measure does not read ServiceRequest"
          "hospice recorded only as a ServiceRequest is not hospice to NCQA's logic"
          (edge "EXC-13")
          (lines "ServiceRequest" '("385763009")))
   (cause "engine" "cql: Quantity.value / .unit are null"
          "the interpreter returns null for (45 days).value and .unit, so an allowed coverage gap fails continuous enrollment (a cql bug)"
          (edge "ENR-01")
          coverages)))

;; explain : Person -> (or Cause #f)
(define (explain m) (for/first ([c causes] #:when ((cause-matches? c) m)) c))

;; ---- reporting --------------------------------------------------------------------------------
(define (count-of ms p f) (count (lambda (m) (hash-ref (f m) p)) ms))
(define (pct n d) (if (zero? d) "-" (string-append (~r (* 100 (/ n d)) #:precision '(= 1)) "%")))

;; print-funnel : (listof Person) [(or #f (listof Person))] -> Void   the measure's funnel beside the
;; key's; with a second run (the supplemental what-if), that one too
(define (print-funnel ms [what-if #f])
  (define (col s) (~a s #:width 16 #:align 'right))
  (define (row-of ms label f)
    (case label
      [("members") (length ms)]
      [("eligible (initial population)") (count-of ms 'eligible f)]
      [("excused (exclusions)") (count-of ms 'excused f)]
      [("accountable (denominator)") (count-of ms 'accountable f)]
      [("screened (numerator)") (count-of ms 'screened f)]
      [else (pct (count-of ms 'screened f) (count-of ms 'accountable f))]))
  (printf "~a~a~a~a\n" (~a "" #:width 32) (col "NCQA logic") (if what-if (col "+ supplemental") "") (col "answer key"))
  (for ([label '("members" "eligible (initial population)" "excused (exclusions)" "accountable (denominator)" "screened (numerator)" "rate")])
    (printf "~a~a~a~a\n" (~a label #:width 32) (col (row-of ms label ours))
            (if what-if (col (row-of what-if label ours)) "") (col (row-of ms label theirs)))))

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

;; outcome : (hash population Boolean) -> String   where a member lands in the funnel
(define (outcome p)
  (cond [(not (hash-ref p 'eligible)) "not eligible"]
        [(hash-ref p 'excused) "excused"]
        [(hash-ref p 'screened) "screened"]
        [else "not screened"]))

(define section-titles '(("eligible" . "eligible") ("excused" . "excused") ("screened" . "screened")))

;; print-person : Person -> Void   one member: the key's story, both outcomes, the cause, the evidence
(define (print-person m)
  (define k (person-key m))
  (printf "~a  ~a~a\n" (person-id m) (hash-ref k "description")
          (let ([e (hash-ref k "edge_case")]) (if (equal? e "") "" (format "  [~a]" e))))
  (printf "  NCQA logic: ~a    answer key: ~a\n" (outcome (ours m)) (outcome (theirs m)))
  (define c (and (pair? (differs m)) (explain m)))
  (cond [c (printf "  why they differ: ~a\n    ~a\n" (cause-label c) (cause-explanation c))
           (for ([l ((cause-records c) m)]) (printf "    the record: ~a\n" l))]
        [(pair? (differs m)) (printf "  why they differ: UNEXPLAINED (~a)\n" (differs m))])
  (define ev (person-evidence m))
  (printf "  evidence the measure found~a\n" (if (null? ev) ": none" ""))
  (for ([s section-titles])
    (define these (filter (lambda (e) (equal? (hash-ref e 'section) (car s))) ev))
    (unless (null? these)
      (printf "    ~a\n" (cdr s))
      (for ([e these])
        (printf "      ~a\n" (hash-ref e 'define))
        (for ([i (hash-ref e 'items)]) (printf "        ~a\n" i)))))
  (newline))

;; ---- the interactive report -------------------------------------------------------------------
(define-runtime-path report-template "report-template.html")

;; report-data : (listof Person) -> jsexpr   what the report page shows
(define (report-data ms)
  (define (funnel f) (hasheq 'members (length ms) 'eligible (count-of ms 'eligible f) 'excused (count-of ms 'excused f)
                             'accountable (count-of ms 'accountable f) 'screened (count-of ms 'screened f)))
  (hasheq
   'title "Breast Cancer Screening (NCQA HEDIS BCS-E), measurement year 2025"
   'ours (funnel ours) 'key (funnel theirs)
   'causes (for/list ([c causes])
             (hasheq 'kind (cause-kind c) 'label (cause-label c) 'explanation (cause-explanation c)
                     'count (count (lambda (m) (and (pair? (differs m)) (eq? (explain m) c))) ms)))
   'members
   (for/list ([m ms])
     (define k (person-key m))
     (define c (and (pair? (differs m)) (explain m)))
     (hasheq 'id (person-id m) 'edge (hash-ref k "edge_case") 'story (hash-ref k "description")
             'gender (hash-ref k "gender") 'age (hash-ref k "age_at_mp_end")
             'ours (outcome (ours m)) 'key (outcome (theirs m))
             'differs (map symbol->string (differs m))
             'cause (if c (cause-label c) (if (pair? (differs m)) "unexplained" 'null))
             'records (if c ((cause-records c) m) '())
             'evidence (person-evidence m)))))

;; write-report! : (listof Person) -> Path   report.html: the template with the data inlined
(define (write-report! ms)
  (make-directory* out-dir)
  (define page (string-replace (file->string report-template) "/*BCSE-DATA*/null"
                               ;; </ inside the JSON would end the <script>
                               (string-replace (jsexpr->string (report-data ms)) "</" "<\\/")))
  (define out (build-path out-dir "report.html"))
  (call-with-output-file out #:exists 'replace (lambda (o) (write-string page o)))
  (simplify-path out))

;; ---- the animated walkthrough -----------------------------------------------------------------
(define-runtime-path walkthrough-template "walkthrough-template.html")

;; the members the walkthrough follows, each found by what it shows: (title . Person -> Boolean)
(define (has-define? m name) (for/or ([e (person-evidence m)]) (equal? (hash-ref e 'define) name)))
(define (edge-is? m e) (equal? (hash-ref (person-key m) "edge_case") e))
(define walkthrough-picks
  (list (cons "Screened, by a claim" (lambda (m) (and (edge-is? m "") (null? (differs m)) (has-define? m "Claims for mammography"))))
        (cons "Screened, but only on a Procedure" (lambda (m) (and (edge-is? m "") (let ([c (explain m)]) (and c (pair? (differs m)) (equal? (cause-kind c) "data"))))))
        (cons "Too young" (lambda (m) (edge-is? m "AGE-02")))
        (cons "Excused: bilateral mastectomy" (lambda (m) (edge-is? m "EXC-01")))
        (cons "Frailty on one date" (lambda (m) (edge-is? m "EXC-16")))))

;; walkthrough-data : (listof Person) -> jsexpr
(define (walkthrough-data ms)
  (define (funnel f) (hasheq 'members (length ms) 'eligible (count-of ms 'eligible f) 'excused (count-of ms 'excused f)
                             'accountable (count-of ms 'accountable f) 'screened (count-of ms 'screened f)))
  (hasheq
   'funnel (hasheq 'ours (funnel ours) 'key (funnel theirs))
   'members
   (for*/list ([p walkthrough-picks] [m (in-value (findf (cdr p) ms))] #:when m)
     (define k (person-key m))
     (define c (and (pair? (differs m)) (explain m)))
     (define cited (append (append-map (lambda (e) (hash-ref e 'items)) (person-evidence m)) (if c ((cause-records c) m) '())))
     (define lines (for/list ([r (person-resources m)]) (cons (hash-ref r 'resourceType) (resource-line r))))
     (define (used? l) (for/or ([x cited]) (string-prefix? x (cdr l))))
     (define first-types '("Patient" "Coverage"))
     (define shown (append (filter (lambda (l) (member (car l) first-types)) lines)
                           (filter (lambda (l) (and (not (member (car l) first-types)) (used? l))) lines)))
     (define others (filter (lambda (l) (not (member l shown))) lines))
     (define ev (person-evidence m))
     (define (gate section pass)
       (hasheq 'pass pass
               'evidence (for/list ([e ev] #:when (and (equal? (hash-ref e 'section) section)
                                                       (not (equal? (hash-ref e 'define) "Mammography screening period"))))
                           (hasheq 'define (hash-ref e 'define) 'items (hash-ref e 'items)))))
     (define o (ours m))
     (hasheq 'id (person-id m) 'title (car p) 'story (hash-ref k "description")
             'age (hash-ref k "age_at_mp_end") 'gender (hash-ref k "gender")
             'records (for/list ([l (append shown (take others (min 4 (length others))))])
                        (hasheq 'type (car l) 'line (cdr l) 'used (and (or (member (car l) first-types) (used? l)) #t)))
             'more (max 0 (- (length others) 4))
             'gates (hasheq 'eligible (gate "eligible" (hash-ref o 'eligible))
                            'excused (gate "excused" (hash-ref o 'excused))
                            'screened (gate "screened" (hash-ref o 'screened)))
             'ours (outcome o) 'key (outcome (theirs m))
             'cause (if c (hasheq 'label (cause-label c) 'explanation (cause-explanation c) 'records ((cause-records c) m)) 'null)
             'report (for/hasheq ([(k v) (car (member-counts (person-defines m)))]) (values (string->symbol k) v))))))

;; write-walkthrough! : (listof Person) -> Path   walkthrough.html: the template with the data inlined
(define (write-walkthrough! ms)
  (make-directory* out-dir)
  (define page (string-replace (file->string walkthrough-template) "/*BCSE-WALKTHROUGH*/null"
                               (string-replace (jsexpr->string (walkthrough-data ms)) "</" "<\\/")))
  (define out (build-path out-dir "walkthrough.html"))
  (call-with-output-file out #:exists 'replace (lambda (o) (write-string page o)))
  (simplify-path out))

;;   racket demo/bcse/population.rkt                 the whole population: tables, reports, report.html
;;   racket demo/bcse/population.rkt bcse-0092 …     those members, each with its evidence
;;   racket demo/bcse/population.rkt --supplemental  the what-if: mammography Procedures also sent as results
(module+ main
  (define ids (vector->list (current-command-line-arguments)))
  (printf "Breast Cancer Screening (NCQA HEDIS BCS-E), measurement year 2025, over a synthetic population\n\n")
  (cond
    [(and (pair? ids) (not (member "--supplemental" ids)))
     (define ms (run-population #:only ids))
     (when ms
       (for ([m ms]) (print-person m))
       (define missing (filter (lambda (id) (not (findf (lambda (m) (equal? (person-id m) id)) ms))) ids))
       (unless (null? missing) (printf "Not in the population: ~a\n" (string-join missing ", "))))]
    [(equal? ids '("--supplemental"))
     (define ms (run-population))
     (define what-if (and ms (run-population #:supplemental? #t)))
     (when ms
       (printf "What if the completed mammography Procedures were also sent as results, the way a HEDIS\nsupplemental data feed carries clinical data? (A data transformation, not NCQA's rule.)\n\n")
       (print-funnel ms what-if)
       (printf "\nWith the supplemental feed:")
       (print-differences what-if))]
    [else
     (define ms (run-population))
     (when ms
       (print-funnel ms)
       (print-differences ms)
       (printf "\nFHIR MeasureReports (the summary, and one per member): ~a\n" (write-reports! ms))
       (printf "Interactive report (every member, with the evidence behind each decision): ~a\n" (write-report! ms))
       (printf "Animated walkthrough (five members through the engine, then all 1,000): ~a\n" (write-walkthrough! ms))
       (printf "One member in detail: racket demo/bcse/population.rkt bcse-0092\n")
       (printf "\nTest data: synthetic members, with NCQA's MY2025 value sets; the members are not real, so the rate is not a plan's HEDIS rate.\n"))]))

(module+ test
  (require rackunit)
  (define ms (and (file-exists? (build-path repo "vendor" "packages" "ncqa.hedis.core.main.v2025-2025.1.0.tgz")) (run-population)))
  (when ms
    (check-equal? (length ms) 1000)
    (check-equal? (filter-map (lambda (m) (and (pair? (differs m)) (not (explain m)) (person-id m))) ms) '()
                  "every disagreement with the answer key has a known cause")
    (check-true (>= (count (lambda (m) (null? (differs m))) ms) 892) "fewer members agree than the floor")
    ;; the evidence trail backs every decision: an excused member shows exclusion evidence, a screened
    ;; one a mammography record (not only the window)
    (define (has-evidence? m section)
      (for/or ([e (person-evidence m)])
        (and (equal? (hash-ref e 'section) section) (not (equal? (hash-ref e 'define) "Mammography screening period")))))
    (check-equal? (filter-map (lambda (m) (and (hash-ref (ours m) 'excused) (not (has-evidence? m "excused")) (person-id m))) ms) '()
                  "every excused member has exclusion evidence")
    (check-equal? (filter-map (lambda (m) (and (hash-ref (ours m) 'screened) (not (has-evidence? m "screened")) (person-id m))) ms) '()
                  "every screened member has a mammography record")
    ;; the what-if: with the mammography Procedures also sent as results, the Procedure-only gap closes
    (define what-if (run-population #:supplemental? #t))
    (check-equal? (filter-map (lambda (m) (and (pair? (differs m)) (not (explain m)) (person-id m))) what-if) '()
                  "with the supplemental feed, every disagreement still has a known cause")
    (check-true (>= (count (lambda (m) (null? (differs m))) what-if) 983) "fewer members agree with the supplemental feed than the floor")))
