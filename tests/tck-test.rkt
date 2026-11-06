#lang racket/base

;;; tck-test.rkt — the floor for the HL7 CQL test suite through SQL (tests/tck.rkt).
;;;
;;; The pass count only rises. A wrong answer is worse than an untranslatable construct, so the
;;; failures are pinned by name: each is a known limit of the SQLite encoding, and any other
;;; failure fails this test.

(require rackunit
         racket/list
         "tck.rkt")

(define pass-floor 902)

;; SQLite's REAL is a double; CQL Decimal is 28 digits with 8 decimal places, and keeps the
;; precision of its lexeme (1.001 ~ 1.000 compares at the less precise operand's precision)
(define known-failures
  '("EquivFloatTrailingZero"
    "Decimal10Pow28ToZeroOneStepDecimalMaxValue"
    "DecimalPos10Pow28ToZeroOneStepDecimalMaxValue"
    "DecimalNeg10Pow28ToZeroOneStepDecimalMinValue"))

(define reports (run-tck))
(define passed (for/sum ([r reports]) (report-pass r)))
(define failed (append-map report-failures reports))
(define unexpected (filter (lambda (f) (not (member (car f) known-failures))) failed))

(printf "SQL TCK: ~a pass, ~a fail, ~a untranslatable, ~a skip\n"
        passed (length failed) (for/sum ([r reports]) (report-untranslatable r)) (for/sum ([r reports]) (report-skip r)))
(for ([f unexpected]) (printf "  unexpected failure ~a: ~a\n    ~s\n" (car f) (cadr f) (caddr f)))

(check-true (>= passed pass-floor) (format "SQL TCK passes ~a, below the floor ~a" passed pass-floor))
(check-equal? (map car unexpected) '() "every SQL TCK failure is a known one")
