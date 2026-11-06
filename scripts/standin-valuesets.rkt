#lang racket/base

;;; standin-valuesets.rkt — TEST-ONLY stand-ins for the NCQA value sets the BCS-E measure names.
;;;
;;; BCS-E's CQL declares its value sets by NCQA url (`https://www.ncqa.org/fhir/ValueSet/…`); their
;;; expansions are NCQA's Value Set Directory, which is licensed separately and not in this repo. So
;;; that the scenarios (scenarios/bcse) can be evaluated end to end, this writes one FSH ValueSet per
;;; declared url: the codes the scenarios use where a scenario reaches the set (the `test-codes`
;;; table), otherwise a single placeholder code from this project's own code system, which no scenario's
;;; data uses (so the set matches nothing real, and is a valid ValueSet: an empty `compose` is not,
;;; and SUSHI and fsh write an empty one differently). Every stand-in is `experimental` and says it is not the NCQA expansion;
;;; a result computed with them is a test of the logic, not a HEDIS rate.
;;;
;;;   racket scripts/standin-valuesets.rkt   -> scenarios/bcse/input/fsh/standin-valuesets.fsh

(require racket/list
         racket/match
         racket/string
         racket/runtime-path
         json
         net/base64)

(define-runtime-path repo "..")

;; A TestCode is (list system code display)
(define cpt "http://www.ama-assn.org/go/cpt")
(define hcpcs "https://www.cms.gov/Medicare/Coding/HCPCSReleaseCodeSets")
(define icd10pcs "http://www.cms.gov/Medicare/Coding/ICD10")
(define sct "http://snomed.info/sct")

;; test-codes : hash url -> (listof TestCode)   real codes from standard code systems, chosen for the
;; scenarios; NOT the NCQA membership of the set
(define test-codes
  (hash
   ;; Mammography
   "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.1168"
   (list (list cpt "77067" "Screening mammography, bilateral")
         (list cpt "77066" "Diagnostic mammography, bilateral")
         (list cpt "77065" "Diagnostic mammography, unilateral"))
   ;; Bilateral Mastectomy
   "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.1042"
   (list (list icd10pcs "0HTV0ZZ" "Resection of Bilateral Breast, Open Approach"))
   ;; Unilateral Mastectomy Left
   "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.1334"
   (list (list icd10pcs "0HTU0ZZ" "Resection of Left Breast, Open Approach"))
   ;; Unilateral Mastectomy Right
   "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.1335"
   (list (list icd10pcs "0HTT0ZZ" "Resection of Right Breast, Open Approach"))
   ;; Hospice Intervention
   "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.1762"
   (list (list sct "385763009" "Hospice care (regime/therapy)"))
   ;; Palliative Care Intervention
   "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.2224"
   (list (list sct "103735009" "Palliative care (regime/therapy)"))
   ;; Medical insurance: the benefit coding the scenarios' Coverage.type carries
   "https://www.ncqa.org/fhir/ValueSet/hedis-medical-insurance-h006"
   (list (list "http://terminology.hl7.org/CodeSystem/v3-ActCode" "HIP" "health insurance plan policy"))
   ;; Medicare coverage types
   "https://www.ncqa.org/fhir/ValueSet/hedis-coverage-type-medicare"
   (list (list "https://ncqa.org/fhir/CodeSystem/hedis-coverage-type" "MP" "Medicare Advantage PPO"))))

;; declared-value-sets : Path -> (listof (cons name url))   every `valueset "Name": 'url'` in the
;; bundle's CQL, first declaration of each url, in url order
(define (declared-value-sets bundle)
  (define b (call-with-input-file bundle read-json))
  (define seen (make-hash))
  (for* ([e (hash-ref b 'entry)]
         [r (in-value (hash-ref e 'resource))] #:when (equal? (hash-ref r 'resourceType) "Library")
         [c (hash-ref r 'content '())] #:when (equal? (hash-ref c 'contentType #f) "text/cql")
         [m (regexp-match* #px"(?m:^valueset \"([^\"]+)\"\\s*:\\s*'([^']+)')"
                           (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref c 'data))))
                           #:match-select cdr)])
    (hash-ref! seen (cadr m) (car m)))
  (sort (for/list ([(url name) (in-hash seen)]) (cons name url)) string<? #:key cdr))

;; fsh-name : String -> String   a FSH/FHIR name: letters and digits, CamelCase, "StandIn" first
(define (fsh-name s)
  (string-append "StandIn" (apply string-append (for/list ([w (regexp-split #px"[^A-Za-z0-9]+" s)] #:unless (equal? w ""))
                                                   (string-append (string-upcase (substring w 0 1)) (substring w 1))))))

;; fsh-id : String -> String   the url's last segment, a valid FHIR id
(define (fsh-id url) (let ([seg (last (string-split url "/"))]) (substring seg 0 (min 64 (string-length seg)))))

;; the placeholder an otherwise-empty stand-in includes: matches no scenario data
(define placeholder (list "https://oloveluck.github.io/cql-to-sql/CodeSystem/standin" "no-scenario-reaches-this-set" "No BCS-E scenario reaches this value set"))

(define (quote-fsh s) (string-append "\"" (regexp-replace* #rx"\"" s "\\\\\"") "\""))

;; value-set-fsh : (cons name url) -> String
(define (value-set-fsh nv)
  (match-define (cons name url) nv)
  (define reached (hash-ref test-codes url '()))
  (define codes (if (null? reached) (list placeholder) reached))
  (string-append
   (format "ValueSet: ~a\nId: ~a\nTitle: ~a\n" (fsh-name name) (fsh-id url) (quote-fsh (string-append name " (TEST-ONLY stand-in)")))
   (format "Description: ~a\n" (quote-fsh (format "TEST-ONLY stand-in for NCQA's \"~a\", not the NCQA Value Set Directory expansion: ~a."
                                                   name (if (null? reached) "a placeholder code only (no scenario reaches it)" "the codes the BCS-E scenarios use"))))
   (format "* ^url = ~a\n* ^experimental = true\n* ^status = #draft\n" (quote-fsh url))
   (apply string-append (for/list ([c codes]) (format "* ~a#~a ~a\n" (car c) (cadr c) (quote-fsh (caddr c)))))))

(module+ main
  (define vss (declared-value-sets (build-path repo "BCSE_Details-2025.3.0.bundle.json")))
  (define out (build-path repo "scenarios" "bcse" "input" "fsh" "standin-valuesets.fsh"))
  (with-output-to-file out #:exists 'replace
    (lambda ()
      (printf "// GENERATED by scripts/standin-valuesets.rkt from BCSE_Details-2025.3.0.bundle.json: do not edit.\n")
      (printf "// TEST-ONLY stand-ins for the ~a NCQA value sets BCS-E declares (not the NCQA VSD).\n\n" (length vss))
      (for ([v vss]) (displayln (value-set-fsh v)))))
  (printf "~a stand-in value sets (~a with test codes) -> ~a\n" (length vss)
          (for/sum ([v vss]) (if (hash-has-key? test-codes (cdr v)) 1 0)) (simplify-path out)))

(module+ test
  (require rackunit)
  (check-equal? (fsh-name "Absence of Left Breast") "StandInAbsenceOfLeftBreast")
  (check-equal? (fsh-id "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.1168") "2.16.840.1.113883.3.464.1004.1168")
  (check-true (regexp-match? #rx"Mammography" (value-set-fsh (cons "Mammography" "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.1168"))))
  (check-true (regexp-match? #rx"77067" (value-set-fsh (cons "Mammography" "https://www.ncqa.org/fhir/ValueSet/2.16.840.1.113883.3.464.1004.1168")))))
