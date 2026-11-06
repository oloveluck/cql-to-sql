#lang racket/base

;;; model-test.rkt — the relational model (model/) over real corpora: it covers what BCS-E reads,
;;; the R4 -> R6 conversion is lossless, every resource loads, and every table column equals what an
;;; independent walk of the data gives (PLAN.md R1-R4). Floors that only rise.
;;;
;;; Corpora: the 1,000-member BCS-E test population (bcse_usqc_testdata_n1000.zip, US Quality
;;; Core, valid FHIR), the 19 BCS-E scenarios on the HEDIS core profiles (when built), and the eCQM
;;; test patients vendored in cql (zone-less dateTimes: built with the eCQM harness's offset,
;;; -07:00, as the interpreter evaluates them).

(require rackunit
         racket/file
         racket/list
         racket/runtime-path
         file/unzip
         "../model/build.rkt"
         "../model/check.rkt"
         "../model/requirements.rkt")

(define-runtime-path root "..")

;; R1: every resource element BCS-E reads is read by some table
(define bcse (build-path root "BCSE_Details-2025.3.0.bundle.json"))
(when (file-exists? bcse)
  (define reqs (requirements (measure-elm (list bcse))))
  (check-true (>= (length reqs) 143) "fewer BCS-E requirements than the floor")
  (check-equal? (map requirement-element (uncovered reqs)) '() "an element BCS-E reads is in no table"))

;; check-corpus : name resources zone floor -> void
(define (check-corpus name rs zone ok-floor)
  (check-equal? (length (round-trip-failures rs)) 0 (format "~a: the R4 -> R6 conversion lost something" name))
  (define-values (c rep) (build-model rs #:zone-offset zone))
  (check-equal? (build-report-unparsed rep) '() (format "~a: resources the R6 model rejected" name))
  (check-equal? (build-report-failures rep) '() (format "~a: tables whose view failed" name))
  (define res (check-tables rs c #:zone-offset zone))
  (define bad (filter (lambda (r) (not (eq? (column-result-status r) 'ok))) res))
  (for ([r bad]) (printf "  ~a ~a.~a ~a\n" (column-result-status r) (column-result-table r) (column-result-column r) (column-result-detail r)))
  (check-equal? (length bad) 0 (format "~a: columns that differ from the data" name))
  (check-true (>= (- (length res) (length bad)) ok-floor) (format "~a: fewer checked columns than the floor" name))
  (printf "model, ~a: ~a resources, ~a rows in ~a tables, ~a/~a columns equal the data, repairs ~a\n"
          name (build-report-resources rep) (for/sum ([(_k v) (build-report-rows rep)]) v) (hash-count (build-report-rows rep))
          (- (length res) (length bad)) (length res) (build-report-repairs rep)))

;; the 1,000-member population
(define n1000-zip (build-path root "bcse_usqc_testdata_n1000.zip"))
(when (file-exists? n1000-zip)
  (define tmp (make-temporary-file "n1000-~a" 'directory))
  (parameterize ([current-directory tmp]) (unzip n1000-zip))
  (check-corpus "n1000" (read-resources (list tmp)) #f 309)
  (delete-directory/files tmp))

;; the 19 BCS-E scenarios, as SUSHI builds them (scenarios/bcse/fsh-generated, gitignored: run
;; `racket scripts/install-hedis.rkt`, `sushi build scenarios/bcse`, install-hedis again)
(define scenarios (build-path root "scenarios" "bcse" "fsh-generated" "resources"))
(define scenario-bundles
  (if (directory-exists? scenarios)
      (for/list ([f (directory-list scenarios #:build? #t)] #:when (regexp-match? #rx"/Bundle-bcse-[^/]*[.]json$" (path->string f))) f)
      '()))
(if (null? scenario-bundles)
    (printf "model, BCS-E scenarios: SKIPPED, not built (scenarios/bcse: install-hedis, sushi build)\n")
    (check-corpus "BCS-E scenarios" (read-resources scenario-bundles) #f 309))

;; the eCQM test patients
(define ecqm (with-handlers ([exn:fail? (lambda (_) #f)]) (collection-file-path "tests" "cql" "tests" "vendor" "ecqm")))
(when (and ecqm (directory-exists? ecqm))
  (check-corpus "eCQM" (read-resources (list ecqm)) "-07:00" 309))

;; the check is not vacuous: a value lost on the way is found
(when (and ecqm (directory-exists? ecqm))
  (define rs (read-resources (list ecqm)))
  (define enc (findf (lambda (r) (and (equal? (hash-ref r 'resourceType) "Encounter") (hash? (hash-ref r 'period #f)))) rs))
  (define broken (for/list ([r rs]) (if (eq? r enc) (hash-remove r 'period) r)))
  (define-values (c _rep) (build-model broken #:zone-offset "-07:00"))
  (check-not-equal? (filter (lambda (r) (eq? (column-result-status r) 'mismatch)) (check-tables rs c #:zone-offset "-07:00")) '()
                    "a lost period went unnoticed"))
