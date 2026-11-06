#lang racket/base

;;; ncqa-valuesets.rkt — NCQA's value sets for the BCS-E demos and tests.
;;;
;;; `2025.3.0.zip` (repo root) is NCQA's HEDIS MY2025 Value Set Directory as FHIR ValueSets, one JSON
;;; file per set (`2.16.840.1.113883.3.464.1004.1168.json` …), each with its full expansion: 842 sets,
;;; covering all 167 that BCS-E's CQL declares. It is read in memory; nothing is extracted.
;;;
;;; Without the zip, the TEST-ONLY stand-ins (scripts/standin-valuesets.rkt, compiled from
;;; scenarios/bcse) take their place, and `bcse-valuesets` says so.

(require racket/contract racket/list racket/port racket/runtime-path racket/set racket/string
         json net/base64 file/unzip
         (only-in fsh/check check-report-artifacts)
         "bcse-check.rkt")

(provide
 (contract-out
  [ncqa-valuesets (-> (or/c #f (listof hash?)))]          ; every set in the zip; #f without it
  [declared-valueset-urls (-> (listof string?))]           ; the urls BCS-E's CQL declares
  [bcse-valuesets (-> (values (listof hash?) (or/c 'ncqa 'stand-in)))]
  [valueset-codes (-> hash? (listof (cons/c string? string?)))]))

(define-runtime-path repo "..")
(define vsd-zip (build-path repo "2025.3.0.zip"))

;; ncqa-valuesets : -> (or #f (listof ValueSet))
(define (ncqa-valuesets)
  (and (file-exists? vsd-zip)
       (let ([out '()])
         (call-with-input-file vsd-zip
           (lambda (in)
             (unzip in (lambda (name dir? content)
                         (unless (or dir? (not (regexp-match? #rx"[.]json$" name)))
                           (define js (bytes->jsexpr (port->bytes content)))
                           (when (and (hash? js) (equal? (hash-ref js 'resourceType #f) "ValueSet"))
                             (set! out (cons js out))))))))
         (reverse out))))

;; declared-valueset-urls : -> (listof url)   every `valueset "…": '<url>'` in BCSE_Details's libraries
(define (declared-valueset-urls)
  (define b (call-with-input-file (build-path repo "BCSE_Details-2025.3.0.bundle.json") read-json))
  (remove-duplicates
   (for*/list ([e (hash-ref b 'entry)] [r (in-value (hash-ref e 'resource))]
               #:when (equal? (hash-ref r 'resourceType) "Library")
               [c (hash-ref r 'content '())] #:when (equal? (hash-ref c 'contentType #f) "text/cql")
               [u (regexp-match* #px"(?m:^valueset \"[^\"]+\"\\s*:\\s*'([^']+)')"
                                 (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref c 'data))))
                                 #:match-select cadr)])
     u)))

;; bcse-valuesets : -> (values (listof ValueSet) source)   NCQA's sets BCS-E declares, or the stand-ins
(define (bcse-valuesets)
  (define all (ncqa-valuesets))
  (cond
    [all
     (define wanted (list->set (declared-valueset-urls)))
     (values (filter (lambda (v) (set-member? wanted (hash-ref v 'url ""))) all) 'ncqa)]
    [else
     (eprintf "ncqa-valuesets: no ~a, so the TEST-ONLY stand-ins are used\n" (simplify-path vsd-zip))
     (values (filter (lambda (a) (equal? (hash-ref a 'resourceType) "ValueSet")) (check-report-artifacts (check-scenarios)))
             'stand-in)]))

;; valueset-codes : ValueSet -> (listof (cons system code))   its expansion
(define (valueset-codes v)
  (for/list ([c (hash-ref (hash-ref v 'expansion (hasheq)) 'contains '())])
    (cons (hash-ref c 'system "") (hash-ref c 'code ""))))

(module+ test
  (require rackunit)
  (when (file-exists? vsd-zip)
    (define-values (vss source) (bcse-valuesets))
    (check-eq? source 'ncqa)
    (check-equal? (length vss) (length (declared-valueset-urls)) "every value set BCS-E declares is in the zip")
    (define mammography (findf (lambda (v) (regexp-match? #rx"[.]1004[.]1168$" (hash-ref v 'url))) vss))
    (check-not-false (member (cons "http://www.ama-assn.org/go/cpt" "77067") (valueset-codes mammography)))))
