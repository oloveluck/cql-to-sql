#lang racket/base

;;; types.rkt — the CQL types the translator tracks, and how each lives in SQL.
;;;
;;; The ELM carries result types only where the cql compiler inferred them, so the translator
;;; computes a type for every term it builds; the type decides the term's SQL encoding.
;;;
;;; A CqlType is one of:
;;; - 'Null                     the type of an untyped null: unifies with anything
;;; - 'Any                      unknown
;;; - 'Boolean 'Integer 'Long 'Decimal 'String 'Date 'DateTime 'Time   scalar System types
;;; - 'Quantity 'Ratio 'Code 'Concept                                    structured System types
;;; - (list 'List CqlType)
;;; - (list 'Interval CqlType)
;;; - (list 'Tuple (listof (cons Symbol CqlType)))
;;; - (list 'Resource String)   a FHIR resource row (a view table's row), by type name
;;;
;;; An Encoding is one of:
;;; - 'native  a SQL scalar: INTEGER for Boolean (0/1), Integer and Long; REAL for Decimal; TEXT for
;;;            String and for Date/DateTime/Time (their ISO lexemes, precision = the lexeme's length)
;;; - 'json    JSON text: lists (arrays), tuples/structured values (objects), intervals
;;;            ({"low","high","lowClosed","highClosed"}), quantities ({"value","unit"}), codes

(require racket/contract
         racket/match)

(provide
 cql-type/c
 (contract-out
  [type-encoding (-> cql-type/c (or/c 'native 'json))]
  [list-type? (-> any/c boolean?)]
  [interval-type? (-> any/c boolean?)]
  [tuple-type? (-> any/c boolean?)]
  [element-type (-> cql-type/c cql-type/c)]          ; of a List or Interval; 'Any otherwise
  [numeric-type? (-> cql-type/c boolean?)]
  [temporal-type? (-> cql-type/c boolean?)]
  [unify (-> cql-type/c cql-type/c cql-type/c)]       ; the common type of two operands
  [system-name->type (-> string? cql-type/c)]))       ; "{urn:hl7-org:elm-types:r1}Integer" / "Integer"

(define scalar-names '(Null Any Boolean Integer Long Decimal String Date DateTime Time Quantity Ratio Code Concept))

(define cql-type/c
  (flat-rec-contract t
    (apply or/c scalar-names)
    (list/c 'List t)
    (list/c 'Interval t)
    (list/c 'Tuple (listof (cons/c symbol? t)))
    (list/c 'Resource string?)))

;; type-encoding : CqlType -> Encoding
(define (type-encoding t)
  (match t
    [(or 'Null 'Any 'Boolean 'Integer 'Long 'Decimal 'String 'Date 'DateTime 'Time) 'native]
    [(list 'Resource _) 'native]          ; a row reference, not a value
    [_ 'json]))

(define (list-type? t) (and (pair? t) (eq? (car t) 'List)))
(define (interval-type? t) (and (pair? t) (eq? (car t) 'Interval)))
(define (tuple-type? t) (and (pair? t) (eq? (car t) 'Tuple)))

(define (element-type t)
  (match t [(list (or 'List 'Interval) e) e] [_ 'Any]))

(define (numeric-type? t) (and (memq t '(Integer Long Decimal)) #t))
(define (temporal-type? t) (and (memq t '(Date DateTime Time)) #t))

;; unify : CqlType CqlType -> CqlType   Null yields to the other; Integer widens to Long and Decimal
;; (CQL's implicit conversions); structured types unify element-wise; anything else is Any
(define (unify a b)
  (match* (a b)
    [('Null t) t] [(t 'Null) t]
    [(t t) t]
    [('Integer 'Decimal) 'Decimal] [('Decimal 'Integer) 'Decimal]
    [('Integer 'Long) 'Long] [('Long 'Integer) 'Long]
    [((list 'List x) (list 'List y)) (list 'List (unify x y))]
    [((list 'Interval x) (list 'Interval y)) (list 'Interval (unify x y))]
    [(_ _) 'Any]))

;; system-name->type : String -> CqlType   a System type by its qualified or simple name
(define (system-name->type s)
  (define simple (match (regexp-match #rx"^{urn:hl7-org:elm-types:r1}(.*)$" s) [(list _ n) n] [_ s]))
  (define sym (string->symbol simple))
  (if (memq sym scalar-names) sym 'Any))

(module+ test
  (require rackunit)
  (check-equal? (type-encoding 'Integer) 'native)
  (check-equal? (type-encoding '(List Integer)) 'json)
  (check-equal? (type-encoding 'Quantity) 'json)
  (check-equal? (unify 'Null 'String) 'String)
  (check-equal? (unify 'Integer 'Decimal) 'Decimal)
  (check-equal? (unify '(List Integer) '(List Decimal)) '(List Decimal))
  (check-equal? (unify 'String 'Integer) 'Any)
  (check-equal? (element-type '(Interval Date)) 'Date)
  (check-equal? (system-name->type "{urn:hl7-org:elm-types:r1}DateTime") 'DateTime)
  (check-equal? (system-name->type "Boolean") 'Boolean)
  (check-equal? (system-name->type "{http://hl7.org/fhir}Patient") 'Any))
