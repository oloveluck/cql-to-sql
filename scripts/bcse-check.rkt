#lang racket/base

;;; bcse-check.rkt — `raco fsh check` for the BCS-E scenarios, with the HEDIS packages in context.
;;;
;;; fsh finds dependency packages in fhir-spec and in `current-package-directories`; the NCQA
;;; package and its dependencies are in `vendor/packages/` (scripts/install-hedis.rkt puts them
;;; there), so this sets that parameter and runs fsh's checker: every scenario compiles, and every
;;; example validates against the HEDIS core profile it claims. Problems print positioned in the FSH.
;;;
;;;   racket scripts/bcse-check.rkt        exit 1 when there is an error

(require racket/list
         racket/runtime-path
         (only-in fhir/spec-package current-package-directories)
         (only-in fhir/diagnostic diagnostic->string diagnostic-severity diagnostic-loc loc-source)
         (only-in fsh/check check-fsh-project check-report-diagnostics check-report-texts
                  check-report-examples check-report-invalid))

(provide check-scenarios)

(define-runtime-path repo "..")

;; check-scenarios : -> check-report   the BCS-E scenario project, checked with the HEDIS packages
(define (check-scenarios)
  (parameterize ([current-package-directories (list (build-path repo "vendor" "packages"))])
    (check-fsh-project (build-path repo "scenarios" "bcse"))))

(module+ main
  (define r (check-scenarios))
  (define ds (check-report-diagnostics r))
  (for ([d ds])
    (define l (diagnostic-loc d))
    (eprintf "~a\n" (diagnostic->string d #:text (and l (loc-source l) (hash-ref (check-report-texts r) (loc-source l) #f)))))
  (define errors (count (lambda (d) (eq? (diagnostic-severity d) 'error)) ds))
  (printf "BCS-E scenarios: ~a examples, ~a invalid, ~a diagnostics (~a errors)\n"
          (check-report-examples r) (check-report-invalid r) (length ds) errors)
  (exit (if (zero? errors) 0 1)))
