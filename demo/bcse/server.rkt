#lang racket/base

;;; server.rkt — BCS-E evaluated by a FHIR server: the 1,000-member population in a FHIR store, and
;;; Measure/$evaluate-measure called over the FHIR API, the way a measure-calculation service runs.
;;;
;;;   racket demo/bcse/server.rkt                  load, evaluate, compare with the in-memory run
;;;   racket demo/bcse/server.rkt --serve 8080     … then keep the server up for curl or a browser
;;;   racket demo/bcse/server.rkt --fresh          reload the store (kept in demo/out/bcse-server.db)
;;;
;;; The server is fhir-server (../fhir): a SQLite FHIR store behind the CQF Measures IG's
;;; measure-calculation-service CapabilityStatement, whose $evaluate-measure is cql/measure over the
;;; store (fhir-server/store/measure.rkt). Everything goes in through the server's own transaction
;;; endpoint (POST /):
;;; - the Measure and its 43 Libraries (BCSE_Details-2025.3.0.bundle.json), CQL in Library.content;
;;; - NCQA's 167 ValueSets that BCS-E declares (2025.3.0.zip);
;;; - the population's 11,770 resources, after the Coverage adapter (population.rkt).
;;; Then GET /Measure/BCSE-Details/$evaluate-measure?periodStart=…&periodEnd=… returns the summary
;;; MeasureReport, and …&subject=Patient/<id> one member's.
;;;
;;; The server applies FHIR's population rules to the Measure's own criteria: an exclusion counts
;;; only inside the "Denominator" define, which NCQA already writes as eligible and not excluded, so
;;; the server's report shows no exclusions, and its denominator is the accountable members. The
;;; rate is the same. This compares the server's counts with that rule applied to the in-memory
;;; run's defines (population.rkt), group by group.
;;;
;;; Run it with the up-to-date cql, and with compiled files kept out of the fhir and cql checkouts:
;;;   PLTCOLLECTS="$HOME/.local/share/cql-upstream:" PLTCOMPILEDROOTS="<scratch dir>:same" racket demo/bcse/server.rkt

(require racket/contract racket/file racket/format racket/list racket/path racket/runtime-path racket/string json
         (only-in fhir/http/router handle)
         (only-in fhir/store/fhir-sqlite open-fhir-store close-fhir-store)
         (only-in fhir/spec-package spec-package-path)
         (only-in fhir/store/ig-server make-ig-server ig-server-app)
         (only-in fhir/http/server serve-app)
         "measure.rkt"
         "population.rkt")

(provide
 (contract-out
  [run-server (->* () (#:keep? boolean? #:fresh? boolean?) (values hash? hash? procedure?))]))   ; summary, individual bcse-0092, app

(define period '((periodStart . "2025-01-01") (periodEnd . "2025-12-31")))
(define example-member "bcse-0092")

;; transaction : (listof resource) -> Bundle   PUT each by its id (ids and references kept)
(define (transaction rs)
  (hasheq 'resourceType "Bundle" 'type "transaction"
          'entry (for/list ([r rs])
                   (hasheq 'resource r 'request (hasheq 'method "PUT" 'url (format "~a/~a" (hash-ref r 'resourceType) (hash-ref r 'id)))))))

;; the store, kept between runs: loading 11,770 resources (each indexed for search) takes a while, so a
;; store that already holds the Measure is reused
(define-runtime-path store-path "../out/bcse-server.db")

;; run-server : -> (values summary individual app)   a loaded measure server and its two reports
(define (run-server #:keep? [keep? #f] #:fresh? [fresh? #f])
  (make-directory* (let-values ([(dir _n _d) (split-path store-path)]) dir))
  (define loaded-marker (path-add-extension store-path #".loaded"))
  ;; a store whose load did not finish is never reused
  (when (or fresh? (not (file-exists? loaded-marker)))
    (for ([f (list store-path loaded-marker)] #:when (file-exists? f)) (delete-file f)))
  (define reuse? (file-exists? loaded-marker))
  (define store (open-fhir-store store-path))
  (define srv (make-ig-server store (spec-package-path "hl7.fhir.us.cqfmeasures-5.0.0.tgz")
                              #:capability "measure-calculation-service-example" #:validate? #f #:offset 0))
  (define app (ig-server-app srv))
  (define (go method path [q '()] [body ""]) (call-with-values (lambda () (handle app method path q body)) list))
  (define (timed what thunk)
    (define t0 (current-inexact-milliseconds))
    (begin0 (thunk) (printf "  ~a (~as)\n" what (~r (/ (- (current-inexact-milliseconds) t0) 1000) #:precision 1))))
  (cond
    [reuse? (printf "The FHIR store (SQLite) is already loaded: ~a (--fresh reloads it)\n" (simplify-path store-path))]
    [else
     (printf "Loading the FHIR store (SQLite, ~a) through POST /:\n" (simplify-path store-path))
     (define population (export-resources (read-export)))
     (for ([part (list (list "the Measure and its 43 Libraries" (measure-resources))
                       (list "NCQA's 167 ValueSets (MY2025)" (measure-valuesets))
                       (list (format "~a member resources (after the Coverage adapter)" (length population)) population))])
       (define r (timed (car part) (lambda () (go "POST" "/" '() (jsexpr->string (transaction (cadr part)))))))
       (unless (= (car r) 200) (error 'server "loading ~a: HTTP ~a ~a" (car part) (car r) (cadr r))))
     (call-with-output-file loaded-marker #:exists 'replace (lambda (o) (write-string "loaded\n" o)))])
  (printf "\nGET /Measure/BCSE-Details/$evaluate-measure?periodStart=2025-01-01&periodEnd=2025-12-31\n")
  (define summary (timed "the summary MeasureReport" (lambda () (go "GET" "/Measure/BCSE-Details/$evaluate-measure" period))))
  (define individual
    (timed (format "and with &subject=Patient/~a, its individual MeasureReport" example-member)
           (lambda () (go "GET" "/Measure/BCSE-Details/$evaluate-measure" (cons (cons 'subject (string-append "Patient/" example-member)) period)))))
  (unless keep? (close-fhir-store store))
  (values (cadr summary) (cadr individual) app))

;; ---- reading a MeasureReport --------------------------------------------------------------------
;; report-counts : MeasureReport -> (listof (hash code count))   per group
(define (report-counts report)
  (for/list ([g (hash-ref report 'group '())])
    (for/hash ([p (hash-ref g 'population '())])
      (values (hash-ref (car (hash-ref (hash-ref p 'code) 'coding)) 'code) (hash-ref p 'count)))))
(define (report-scores report)
  (for/list ([g (hash-ref report 'group '())]) (hash-ref (hash-ref g 'measureScore (hasheq)) 'value #f)))

;; server-rule-counts : (listof Person) -> (listof (hash code count))   what a server applying FHIR's
;; rules to the Measure's criteria must report, from the in-memory defines
(define (server-rule-counts people)
  (for/list ([g '(("Exclusion" "Denominator") ("Exclusion - Medicare" "Denominator - Medicare"))])
    (for/fold ([acc (hash "initial-population" 0 "denominator" 0 "denominator-exclusion" 0 "numerator" 0)]) ([m people])
      (define d (person-defines m))
      (define ip (hash-ref d "Initial population"))
      (define den (and ip (hash-ref d (cadr g))))
      (define excl (and den (hash-ref d (car g))))
      (define num (and den (not excl) (hash-ref d "Numerator")))
      (for/fold ([a acc]) ([k '("initial-population" "denominator" "denominator-exclusion" "numerator")] [b (list ip den excl num)])
        (if b (hash-update a k add1) a)))))

(define (print-report report)
  (for ([g (hash-ref report 'group '())] [c (report-counts report)] [s (report-scores report)])
    (printf "  ~a: ~a~a\n" (hash-ref g 'id "")
            (string-join (for/list ([k '("initial-population" "denominator" "denominator-exclusion" "numerator")] #:when (hash-has-key? c k))
                           (format "~a ~a" k (hash-ref c k))) ", ")
            (if s (format ", score ~a%" (~r (* 100 s) #:precision '(= 1))) ""))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define port (let ([m (member "--serve" args)]) (and m (string->number (if (pair? (cdr m)) (cadr m) "8080")))))
  (printf "BCS-E (NCQA HEDIS, MY2025) through a FHIR server's Measure/$evaluate-measure\n\n")
  (define-values (summary individual app) (run-server #:keep? (and port #t) #:fresh? (and (member "--fresh" args) #t)))
  (printf "\nThe server's summary MeasureReport (~a):\n" (hash-ref summary 'type))
  (print-report summary)
  (printf "Its individual MeasureReport for ~a (~a):\n" example-member (hash-ref individual 'type))
  (print-report individual)
  (printf "\nThe same measure evaluated in memory (population.rkt), counted by the server's rule:\n")
  (define people (run-population))
  (define expected (server-rule-counts people))
  (for ([g '("BreastCancerScreening" "BreastCancerScreening-Medicare")] [c expected])
    (printf "  ~a: ~a\n" g (string-join (for/list ([k '("initial-population" "denominator" "denominator-exclusion" "numerator")])
                                          (format "~a ~a" k (hash-ref c k))) ", ")))
  (printf "~a\n" (if (equal? expected (report-counts summary))
                     "The server and the in-memory run agree on every population of both groups."
                     "THE SERVER AND THE IN-MEMORY RUN DIFFER."))
  (printf "(The server shows no exclusions: NCQA's \"Denominator\" already leaves the excluded out, and the rate is the same.)\n")
  (when port
    (define stop (serve-app app #:port port))
    (printf "\nServing on http://localhost:~a (Ctrl-C to stop). Try:\n" port)
    (printf "  curl 'http://localhost:~a/Measure/BCSE-Details/$evaluate-measure?periodStart=2025-01-01&periodEnd=2025-12-31'\n" port)
    (printf "  curl 'http://localhost:~a/Measure/BCSE-Details/$evaluate-measure?periodStart=2025-01-01&periodEnd=2025-12-31&subject=Patient/~a'\n" port example-member)
    (printf "  curl 'http://localhost:~a/Patient/~a'\n" port example-member)
    (with-handlers ([exn:break? (lambda (_) (stop))]) (sync never-evt))))

(module+ test
  (require rackunit racket/runtime-path)
  (define-runtime-path hedis-package "../../vendor/packages/ncqa.hedis.core.main.v2025-2025.1.0.tgz")
  (when (file-exists? hedis-package)
    (define-values (summary individual _app) (run-server))
    (check-equal? (hash-ref summary 'type) "summary")
    (check-equal? (hash-ref individual 'type) "individual")
    (check-equal? (report-counts summary) (server-rule-counts (run-population))
                  "the server's MeasureReport counts what the in-memory run's defines give")))
