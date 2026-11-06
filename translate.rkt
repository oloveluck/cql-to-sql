#lang racket/base

;;; translate.rkt — CQL's ELM (cql/elm/ast) as SQL (sql/ast), one clause per ELM variant.
;;;
;;; Every ELM expression becomes a Term: (term sql type), a SQL expression whose value encodes a CQL
;;; value of `type` (types.rkt: native scalars; JSON text for lists, tuples, intervals, quantities,
;;; codes). The interpreter (cql/interp's eval-elm) is the semantic reference; operators live in a
;;; registry (def-op!) keyed by the ELM operator name, like the interpreter's OPS, so coverage can be
;;; counted against it.
;;;
;;; What has no SQL translation yet raises exn:fail:untranslatable (with the ELM node) — never
;;; SQL that computes something else.
;;;
;;; A TEnv is (tenv dialect aliases lets):
;;;   dialect : Dialect (sql/dialect)
;;;   aliases : hash String -> Term   query aliases in scope (a source row's value)
;;;   lets    : hash String -> Term

(require racket/contract
         racket/list
         racket/match
         racket/string
         cql/elm/ast
         "types.rkt"
         "sql/ast.rkt"
         "sql/dialect.rkt")

(provide
 (struct-out term)
 (struct-out tenv)
 (struct-out exn:fail:untranslatable)
 (contract-out
  [translate (-> any/c tenv? term?)]
  [make-tenv (->* () (#:dialect dialect?) tenv?)]
  [translated-ops (-> (listof string?))]))     ; the ELM operator names with a translation

(struct term (sql type) #:transparent)
(struct tenv (dialect aliases lets))
(struct exn:fail:untranslatable exn:fail (node) #:transparent)

(define (make-tenv #:dialect [d sqlite]) (tenv d (hash) (hash)))

;; untranslatable : ELM FormatString Any ... -> (raises)
(define (untranslatable node fmt . args)
  (raise (exn:fail:untranslatable (apply format fmt args) (current-continuation-marks) node)))

;; D : TEnv OpName SqlExpr ... -> SqlExpr   a dialect operation
(define (D env op . args) (apply dialect-op (tenv-dialect env) op args))

;; ---- the translation -------------------------------------------------------------------------

;; translate : ELM TEnv -> Term
(define (translate e env)
  (match e
    [(elm-literal t v) (literal t v e)]
    [(elm-null t) (term sql-null (if t (system-name->type t) 'Null))]
    [(elm-quantity v unit)
     (term (D env 'json-object (sql-lit "value") (sql-lit (string->number v)) (sql-lit "unit") (sql-lit (or unit "1")))
           'Quantity)]
    [(elm-nary op args rt) (apply-op op (for/list ([a args]) (translate a env)) rt env e)]
    [(elm-unary op a rt) (apply-op op (list (translate a env)) rt env e)]
    [(elm-if c th el)
     (define tt (translate th env)) (define et (translate el env))
     (term (sql-case (list (cons (truthy (translate c env)) (term-sql tt))) (term-sql et))
           (unify (term-type tt) (term-type et)))]
    [(elm-case comparand items els)
     (define cmp (and comparand (translate comparand env)))
     (define arms (for/list ([it items])
                    (define w (translate (elm-case-item-when it) env))
                    (cons (if cmp (sql-bin "=" (term-sql cmp) (term-sql w)) (truthy w))
                          (translate (elm-case-item-then it) env))))
     (define et (translate els env))
     (term (sql-case (for/list ([a arms]) (cons (car a) (term-sql (cdr a)))) (term-sql et))
           (foldl unify (term-type et) (map (lambda (a) (term-type (cdr a))) arms)))]
    [(elm-list elements)
     (define ts (for/list ([x elements]) (translate x env)))
     (term (apply D env 'json-array (map (lambda (t) (embed t env)) ts))
           (list 'List (foldl unify 'Null (map term-type ts))))]
    [(elm-tuple elems)
     (define fields (for/list ([el elems]) (cons (elm-tuple-elem-name el) (translate (elm-tuple-elem-value el) env))))
     (tuple-term fields env)]
    [(elm-interval lo hi lc hc) (interval-term (translate lo env) (translate hi env) lc hc env)]
    [(elm-date y m d) (temporal-literal e 'Date (list y m d) env)]
    [(elm-datetime y mo d h mi s ms off) (temporal-literal e 'DateTime (list y mo d h mi s ms) env #:offset off)]
    [(elm-time h mi s ms) (temporal-literal e 'Time (list h mi s ms) env)]
    [(elm-alias-ref n) (hash-ref (tenv-aliases env) n (lambda () (untranslatable e "alias ~a is not in scope" n)))]
    [(elm-query-let-ref n) (hash-ref (tenv-lets env) n (lambda () (untranslatable e "let ~a is not in scope" n)))]
    [(elm-property src path scope) (property e src path scope env)]
    [(elm-query sources lets rels where ret distinct? sort agg) (query e sources lets rels where ret distinct? sort agg env)]
    [(elm-as operand type strict?) (let ([t (translate operand env)]) (term (term-sql t) (type-spec->type type (term-type t))))]
    [(elm-is operand type) (is-test e (translate operand env) (type-spec->type type 'Any))]
    [(elm-to operand to-type) (apply-op (string-append "To" to-type) (list (translate operand env)) to-type env e)]
    [(elm-component prec operand) (component e prec (translate operand env) env)]
    [_ (untranslatable e "~a has no SQL translation yet" (elm-kind e))]))

;; elm-kind : ELM -> String   the node's struct name, for messages
(define (elm-kind e)
  (define k (prefab-struct-key e))
  (if k (format "~a" (if (pair? k) (car k) k)) (format "~a" e)))

;; ---- literals ----------------------------------------------------------------------------------

;; literal : String String ELM -> Term
(define (literal t v e)
  (match t
    ["Boolean" (term (if (equal? v "true") sql-true sql-false) 'Boolean)]
    ["Integer" (term (sql-lit (string->number v)) 'Integer)]
    ["Long" (term (sql-lit (string->number v)) 'Long)]
    ["Decimal" (term (sql-lit (exact->inexact (string->number v))) 'Decimal)]
    ["String" (term (sql-lit v) 'String)]
    [_ (untranslatable e "a ~a literal" t)]))

;; ---- encodings ---------------------------------------------------------------------------------

;; embed : Term TEnv -> SqlExpr   the term as a member of a JSON array or object
(define (embed t env)
  (match (term-type t)
    ['Boolean (D env 'json-embed (sql-case (list (cons (truthy t) (sql-lit "true"))
                                                 (cons (sql-un "NOT" (term-sql t)) (sql-lit "false")))
                                           sql-null))]
    [ty (if (eq? (type-encoding ty) 'json) (D env 'json-embed (term-sql t)) (term-sql t))]))

;; truthy : Term -> SqlExpr   a Boolean term as a SQL condition
(define (truthy t) (term-sql t))

;; extracted : SqlExpr CqlType -> Term   a value read out of JSON (json_each.value, json_extract)
(define (extracted sql type) (term sql type))

;; tuple-term : (listof (cons Symbol Term)) TEnv -> Term
(define (tuple-term fields env)
  (term (apply D env 'json-object (append* (for/list ([f fields]) (list (sql-lit (symbol->string (car f))) (embed (cdr f) env)))))
        (list 'Tuple (for/list ([f fields]) (cons (car f) (term-type (cdr f)))))))

;; interval-term : Term Term Boolean Boolean TEnv -> Term
(define (interval-term lo hi lc hc env)
  (term (D env 'json-object (sql-lit "low") (embed lo env) (sql-lit "high") (embed hi env)
           (sql-lit "lowClosed") (D env 'json-embed (sql-lit (if lc "true" "false")))
           (sql-lit "highClosed") (D env 'json-embed (sql-lit (if hc "true" "false"))))
        (list 'Interval (unify (term-type lo) (term-type hi)))))

;; field : Term String CqlType TEnv -> Term   a member of a JSON-encoded value
(define (field t name type env)
  (extracted (D env 'json-extract (term-sql t) (sql-lit (string-append "$." name))) type))

;; ---- types -------------------------------------------------------------------------------------

;; type-spec->type : TypeSpec CqlType -> CqlType
(define (type-spec->type spec fallback)
  (match spec
    [(elm-named-type n) (let ([t (system-name->type n)]) (if (eq? t 'Any) fallback t))]
    [(elm-list-type el) (list 'List (type-spec->type el 'Any))]
    [(elm-interval-type p) (list 'Interval (type-spec->type p 'Any))]
    [_ fallback]))

;; is-test : ELM Term CqlType -> Term   `x is T` decided from the static type (null is not anything)
(define (is-test e t ty)
  (cond
    [(eq? ty 'Any) (untranslatable e "an `is` test against a type the translator does not know")]
    [(memq (term-type t) '(Any)) (untranslatable e "an `is` test on a value of unknown type")]
    [else (term (if (equal? (unify (term-type t) ty) ty)
                    (if (equal? (term-type t) 'Null) sql-false (sql-null-test (term-sql t) #t))
                    sql-false)
                'Boolean)]))

;; ---- properties --------------------------------------------------------------------------------

;; property : ELM ELM|#f String String|#f TEnv -> Term
(define (property e src path scope env)
  (define base (cond [src (translate src env)]
                     [scope (hash-ref (tenv-aliases env) scope (lambda () (untranslatable e "alias ~a is not in scope" scope)))]
                     [else (untranslatable e "a property without a source")]))
  (match (term-type base)
    [(list 'Tuple fields)
     (define ft (cond [(assq (string->symbol path) fields) => cdr] [else 'Any]))
     (field base path ft env)]
    [(list 'Interval p)
     (match path
       [(or "low" "high") (field base path p env)]
       [(or "lowClosed" "highClosed") (field base path 'Boolean env)]
       [_ (untranslatable e "Interval has no property ~a" path)])]
    ['Quantity
     (match path ["value" (field base "value" 'Decimal env)] ["unit" (field base "unit" 'String env)]
       [_ (untranslatable e "Quantity has no property ~a" path)])]
    [t (untranslatable e "property ~a of a ~a value" path t)]))

;; ---- queries over lists ------------------------------------------------------------------------

;; query : ELM ... -> Term   sources (lists, each a json_each), with/without as EXISTS, where,
;; return (distinct unless `all`), sort; the result a JSON list (or the single value of a
;; singleton source)
(define (query e sources lets rels where ret distinct? sort agg env)
  (when agg (untranslatable e "an aggregate clause"))
  (define srcs (for/list ([s sources]) (cons (car s) (translate (cdr s) env))))
  (define singleton? (for/and ([s srcs]) (not (list-type? (term-type (cdr s))))))
  (unless (or singleton? (for/and ([s srcs]) (list-type? (term-type (cdr s)))))
    (untranslatable e "a query mixing list and single-value sources"))
  ;; each source alias is a FROM item; its value is the row's `value` column
  (define aliases
    (for/fold ([h (tenv-aliases env)]) ([s srcs])
      (hash-set h (car s) (extracted (sql-ref (car s) "value")
                                     (if singleton? (term-type (cdr s)) (element-type (term-type (cdr s))))))))
  (define env1 (tenv (tenv-dialect env) aliases (tenv-lets env)))
  (define env2 (for/fold ([en env1]) ([l lets])
                 (tenv (tenv-dialect en) (tenv-aliases en) (hash-set (tenv-lets en) (car l) (translate (cdr l) en)))))
  (define from
    (for/list ([s srcs])
      (if singleton?
          (sql-subquery (select (cons (term-sql (cdr s)) "value")) (car s))
          (sql-table-fn (D env 'json-each (term-sql (cdr s))) (car s)))))
  (define conds
    (append (for/list ([r rels]) (relationship r env2))
            (if where (list (truthy (translate where env2))) '())))
  (define value
    (cond [ret (translate ret env2)]
          [(= (length srcs) 1) (hash-ref aliases (car (car srcs)))]
          [else (tuple-term (for/list ([s srcs]) (cons (string->symbol (car s)) (hash-ref aliases (car s)))) env2)]))
  (define order (sort-clause e sort value env2))
  (define where-sql (if (null? conds) #f (apply sql-and conds)))
  (cond
    [singleton?
     (term (sql-scalar (select (term-sql value) #:from from #:where where-sql)) (term-type value))]
    [else
     (define rows (select #:distinct? (and ret distinct? #t) (cons (embed value env2) "v") #:from from #:where where-sql #:order-by order))
     ;; json_group_array over an ordered subquery keeps that order (SQLite); a null source list is a null result
     (define agg-sql (sql-scalar (select (D env 'json-group-array (sql-ref "q" "v")) #:from (list (sql-subquery rows "q")))))
     (define null-source (apply sql-or (for/list ([s srcs]) (sql-null-test (term-sql (cdr s)) #f))))
     (term (sql-case (list (cons null-source sql-null)) agg-sql) (list 'List (term-type value)))]))

;; relationship : elm-relationship TEnv -> SqlExpr   with: EXISTS; without: NOT EXISTS
(define (relationship r env)
  (match-define (elm-relationship kind alias expr such-that) r)
  (define src (translate expr env))
  (define elem (if (list-type? (term-type src)) (element-type (term-type src)) (term-type src)))
  (define inner (tenv (tenv-dialect env) (hash-set (tenv-aliases env) alias (extracted (sql-ref alias "value") elem)) (tenv-lets env)))
  (define from (if (list-type? (term-type src))
                   (sql-table-fn (D env 'json-each (term-sql src)) alias)
                   (sql-subquery (select (cons (term-sql src) "value")) alias)))
  (define ex (sql-exists (select (sql-lit 1) #:from (list from) #:where (truthy (translate such-that inner)))))
  (if (eq? kind 'with) ex (sql-un "NOT" ex)))

;; sort-clause : ELM SortSpec Term TEnv -> (listof (cons SqlExpr Direction))
(define (sort-clause e sort value env)
  (match sort
    [#f '()]
    [(list (elm-sort-by 'direction dir _)) (list (cons (term-sql value) (if (equal? dir "desc") 'desc 'asc)))]
    [bys (for/list ([b bys])
           (match b
             [(elm-sort-by 'column dir path)
              (unless (tuple-type? (term-type value)) (untranslatable e "sorting by a column of a non-tuple"))
              (cons (term-sql (field value path (cond [(assq (string->symbol path) (cadr (term-type value))) => cdr] [else 'Any]) env))
                    (if (equal? dir "desc") 'desc 'asc))]
             [_ (untranslatable e "this sort clause")]))]))

;; ---- temporal ----------------------------------------------------------------------------------

;; the lexeme position of each component (1-based start, length), for Date/DateTime lexemes
(define date-parts '((year 1 4) (month 6 2) (day 9 2) (hour 12 2) (minute 15 2) (second 18 2) (millisecond 21 3)))
(define time-parts '((hour 1 2) (minute 4 2) (second 7 2) (millisecond 10 3)))

;; temporal-literal : ELM Type (listof ELM|#f) TEnv [#:offset] -> Term   folded to its ISO lexeme
;; when every component is a literal
(define (temporal-literal e type comps env #:offset [off #f])
  (define vals (for/list ([c comps]) (match c [#f #f] [(elm-literal _ v) (string->number v)] [_ 'computed])))
  (when (or (memq 'computed vals) (and off (not (elm-literal? off))))
    (untranslatable e "a ~a built from computed components" type))
  (define present (takef vals values))
  (define (pad n w) (let ([s (number->string n)]) (string-append (make-string (max 0 (- w (string-length s))) #\0) s)))
  (define lexeme
    (match type
      ['Time (string-append* (for/list ([v present] [sep '("" ":" ":" ".")] [w '(2 2 2 3)]) (string-append sep (pad v w))))]
      [_ (string-append*
          (for/list ([v present] [sep '("" "-" "-" "T" ":" ":" ".")] [w '(4 2 2 2 2 2 3)]) (string-append sep (pad v w))))]))
  (define offset
    (match off
      [#f ""]
      [(elm-literal _ v)
       (define minutes (inexact->exact (round (* 60 (string->number v)))))
       (if (zero? minutes) "Z"
           (format "~a~a:~a" (if (negative? minutes) "-" "+") (pad (quotient (abs minutes) 60) 2) (pad (remainder (abs minutes) 60) 2)))]))
  (term (sql-lit (string-append lexeme (if (> (length present) 3) offset ""))) type))

;; component : ELM Symbol Term TEnv -> Term   `year from x`: the lexeme's digits, null below its precision
(define (component e prec t env)
  (define parts (if (eq? (term-type t) 'Time) time-parts date-parts))
  (match (assq prec parts)
    [(list _ start len)
     (define s (term-sql t))
     (term (sql-case (list (cons (sql-bin ">=" (D env 'length s) (sql-lit (+ start len -1)))
                                 (D env 'to-integer (D env 'substr s (sql-lit start) (sql-lit len)))))
                     sql-null)
           'Integer)]
    [_ (untranslatable e "~a from a ~a" prec (term-type t))]))

;; temporal-compare : String SqlExpr SqlExpr TEnv -> SqlExpr   CQL comparison of two ISO lexemes:
;; decided by their common prefix when it differs; when it is equal, by the full values if their
;; precisions agree, else null (uncertain). Offsets are assumed equal.
(define (temporal-compare op a b env)
  (define la (D env 'length a)) (define lb (D env 'length b))
  (define n (sql-case (list (cons (sql-bin "<" la lb) la)) lb))
  (define pa (D env 'substr a (sql-lit 1) n)) (define pb (D env 'substr b (sql-lit 1) n))
  (sql-case (list (cons (sql-bin "<>" pa pb) (sql-bin op pa pb))
                  (cons (sql-bin "=" la lb) (sql-bin op a b)))
            (if (member op '("=")) sql-null
                ;; equal prefixes, different precisions: <= and >= hold only if the strict part does not decide
                sql-null)))

;; ---- operators ---------------------------------------------------------------------------------

;; An OpImpl is (listof Term) ResultTypeName|#f TEnv ELM -> Term
(define OPS (make-hash))
(define (def-op! name impl) (hash-set! OPS name impl))
(define (translated-ops) (sort (hash-keys OPS) string<?))

;; apply-op : String (listof Term) String|#f TEnv ELM -> Term
(define (apply-op name args rt env e)
  ((hash-ref OPS name (lambda () (untranslatable e "operator ~a has no SQL translation yet" name))) args rt env e))

(define (rtype rt fallback) (if rt (let ([t (system-name->type rt)]) (if (eq? t 'Any) fallback t)) fallback))

;; numeric helpers
(define (decimal? t) (eq? (term-type t) 'Decimal))
(define (quantity? t) (eq? (term-type t) 'Quantity))
(define (arith-type args) (foldl unify 'Null (map term-type args)))
(define (as-real t env) (if (decimal? t) (term-sql t) (D env 'to-real (term-sql t))))
(define (nonzero-or-null d expr) (sql-case (list (cons (sql-bin "=" d (sql-lit 0)) sql-null)) expr))

;; int-guard : SqlExpr CqlType -> SqlExpr   an Integer result outside 32 bits is null (CQL Integer)
(define (int-guard x ty)
  (if (eq? ty 'Integer)
      (sql-case (list (cons (sql-or (sql-bin "<" x (sql-lit -2147483648)) (sql-bin ">" x (sql-lit 2147483647))) sql-null)) x)
      x))

;; ---- quantities ----
;; A UnitInfo is (list unit eq-key eq-factor equiv-key equiv-factor): the keys name what a unit is
;; comparable with, the factors scale to a common base. Equality keeps CQL's calendar words (year,
;; month) apart from everything but themselves; equivalence uses the spec's pairwise factors
;; (cql/interp/compare: 1 year ~ 12 months ~ 365 days, 1 month ~ 30 days, 'a'/'mo' alias them).
;; A unit outside the table compares only with the identical unit; any other pair is a runtime
;; error (deciding it needs UCUM), never a guess.
(define time-units
  '(("ms" 1) ("millisecond" 1) ("milliseconds" 1) ("s" 1000) ("second" 1000) ("seconds" 1000)
    ("min" 60000) ("minute" 60000) ("minutes" 60000) ("h" 3600000) ("hour" 3600000) ("hours" 3600000)
    ("d" 86400000) ("day" 86400000) ("days" 86400000) ("wk" 604800000) ("week" 604800000) ("weeks" 604800000)))
(define unit-table
  (append
   (for/list ([u time-units]) (list (car u) "time" (cadr u) "time" (cadr u)))
   '(("year" "cal-year" 1 "cal" 12) ("years" "cal-year" 1 "cal" 12)
     ("month" "cal-month" 1 "cal" 1) ("months" "cal-month" 1 "cal" 1)
     ("a" "ucum-a" 1 "cal" 12) ("mo" "ucum-mo" 1 "cal" 1)
     ("mg" "mass" 1/1000 "mass" 1/1000) ("g" "mass" 1 "mass" 1) ("kg" "mass" 1000 "mass" 1000)
     ("mm" "length" 1/1000 "length" 1/1000) ("cm" "length" 1/100 "length" 1/100) ("m" "length" 1 "length" 1) ("km" "length" 1000 "length" 1000)
     ("mL" "volume" 1/1000 "volume" 1/1000) ("dL" "volume" 1/10 "volume" 1/10) ("L" "volume" 1 "volume" 1)
     ("1" "one" 1 "one" 1))))
;; the calendar-word days used when an equivalence crosses calendar and fixed time units
(define cal-days '(("year" 365) ("years" 365) ("a" 365) ("month" 30) ("months" 30) ("mo" 30)))

;; unit-case : SqlExpr (UnitInfo -> Any) SqlExpr -> SqlExpr   a CASE over the unit table
(define (unit-case u pick default)
  (sql-case (for/list ([row unit-table]) (cons (sql-bin "=" u (sql-lit (car row))) (sql-lit (let ([v (pick row)]) (if (rational? v) (exact->inexact v) v))))) default))

(define (qv t env) (D env 'json-extract (term-sql t) (sql-lit "$.value")))
(define (qu t env) (D env 'json-extract (term-sql t) (sql-lit "$.unit")))
(define (quantity-sql v u env) (D env 'json-object (sql-lit "value") v (sql-lit "unit") u))

;; quantity-compare : String Term Term TEnv -> SqlExpr   = < <= > >= by the equality keys
(define (quantity-compare op a b env)
  (define ua (qu a env)) (define ub (qu b env))
  (define ka (unit-case ua cadr (sql-bin "||" (sql-lit "u:") ua)))
  (define kb (unit-case ub cadr (sql-bin "||" (sql-lit "u:") ub)))
  (define (scaled t u) (sql-bin "*" (D env 'to-real (qv t env)) (unit-case u caddr (sql-lit 1.0))))
  (define known? (lambda (u) (sql-un "NOT" (sql-null-test (unit-case u cadr sql-null) #f))))
  (sql-case (list (cons (sql-or (sql-null-test (term-sql a) #f) (sql-null-test (term-sql b) #f)) sql-null)
                  (cons (sql-bin "=" ua ub) (sql-bin op (D env 'round (D env 'to-real (qv a env)) (sql-lit 8)) (D env 'round (D env 'to-real (qv b env)) (sql-lit 8))))
                  (cons (sql-bin "=" ka kb) (sql-bin op (D env 'round (scaled a ua) (sql-lit 8)) (D env 'round (scaled b ub) (sql-lit 8))))
                  (cons (sql-and (known? ua) (known? ub)) sql-null))
            (D env 'error "comparing quantities in units that need UCUM conversion")))

;; quantity-equivalent : Term Term TEnv -> SqlExpr   ~ by the equivalence keys (null ~ null)
(define (quantity-equivalent a b env)
  (define ua (qu a env)) (define ub (qu b env))
  (define ka (unit-case ua cadddr (sql-bin "||" (sql-lit "u:") ua)))
  (define kb (unit-case ub cadddr (sql-bin "||" (sql-lit "u:") ub)))
  (define (scaled t u) (sql-bin "*" (D env 'to-real (qv t env)) (unit-case u (lambda (r) (list-ref r 4)) (sql-lit 1.0))))
  (define (days t u) ;; a duration as days, calendar words by their pairwise day counts
    (sql-bin "*" (D env 'to-real (qv t env))
             (sql-case (append (for/list ([c cal-days]) (cons (sql-bin "=" u (sql-lit (car c))) (sql-lit (exact->inexact (cadr c)))))
                               (for/list ([t time-units]) (cons (sql-bin "=" u (sql-lit (car t))) (sql-lit (exact->inexact (/ (cadr t) 86400000))))))
                       sql-null)))
  (sql-case (list (cons (sql-and (sql-null-test (term-sql a) #f) (sql-null-test (term-sql b) #f)) sql-true)
                  (cons (sql-or (sql-null-test (term-sql a) #f) (sql-null-test (term-sql b) #f)) sql-false)
                  (cons (sql-bin "=" ka kb) (sql-bin "=" (D env 'round (scaled a ua) (sql-lit 8)) (D env 'round (scaled b ub) (sql-lit 8))))
                  (cons (sql-and (sql-bin "=" ka (sql-lit "cal")) (sql-bin "=" kb (sql-lit "time")))
                        (sql-bin "=" (D env 'round (days a ua) (sql-lit 8)) (D env 'round (days b ub) (sql-lit 8))))
                  (cons (sql-and (sql-bin "=" ka (sql-lit "time")) (sql-bin "=" kb (sql-lit "cal")))
                        (sql-bin "=" (D env 'round (days a ua) (sql-lit 8)) (D env 'round (days b ub) (sql-lit 8))))
                  (cons (sql-bin "=" ua ub) (sql-bin "=" (D env 'round (D env 'to-real (qv a env)) (sql-lit 8)) (D env 'round (D env 'to-real (qv b env)) (sql-lit 8)))))
            (D env 'error "comparing quantities in units that need UCUM conversion")))

;; quantity-arith : String Term Term TEnv ELM -> Term   + - on quantities: in a's unit when b converts
(define (quantity-arith op a b env e)
  (define ua (qu a env)) (define ub (qu b env))
  (define ka (unit-case ua cadr (sql-bin "||" (sql-lit "u:") ua)))
  (define kb (unit-case ub cadr (sql-bin "||" (sql-lit "u:") ub)))
  (define fa (unit-case ua caddr (sql-lit 1.0))) (define fb (unit-case ub caddr (sql-lit 1.0)))
  (term (sql-case (list (cons (sql-or (sql-null-test (term-sql a) #f) (sql-null-test (term-sql b) #f)) sql-null)
                        (cons (sql-bin "=" ua ub) (quantity-sql (sql-bin op (qv a env) (qv b env)) ua env))
                        (cons (sql-bin "=" ka kb) (quantity-sql (sql-bin op (qv a env) (sql-bin "/" (sql-bin "*" (qv b env) fb) fa)) ua env)))
                  (D env 'error "quantity arithmetic across units that need UCUM conversion"))
        'Quantity))

;; quantity-scale : Term (SqlExpr -> SqlExpr) TEnv -> Term   the value transformed, the unit kept
(define (quantity-map t f env)
  (term (sql-case (list (cons (sql-null-test (term-sql t) #f) sql-null)) (quantity-sql (f (qv t env)) (qu t env) env)) 'Quantity))

(define (binary-arith sqlop)
  (lambda (args rt env e)
    (match-define (list a b) args)
    (define ty (arith-type args))
    (unless (numeric-type? ty) (untranslatable e "~a on ~a" sqlop ty))
    (term (int-guard (sql-bin sqlop (term-sql a) (term-sql b)) ty) ty)))

(def-op! "Add" (lambda (args rt env e)
                 (match-define (list a b) args)
                 (cond
                   [(eq? (arith-type args) 'String) (term (sql-bin "||" (term-sql a) (term-sql b)) 'String)]
                   [(and (quantity? a) (quantity? b)) (quantity-arith "+" a b env e)]
                   [else ((binary-arith "+") args rt env e)])))
(def-op! "Subtract" (lambda (args rt env e)
                      (match-define (list a b) args)
                      (if (and (quantity? a) (quantity? b)) (quantity-arith "-" a b env e) ((binary-arith "-") args rt env e))))
(def-op! "Multiply" (lambda (args rt env e)
                      (match-define (list a b) args)
                      (cond [(and (quantity? a) (numeric-type? (term-type b))) (quantity-map a (lambda (v) (sql-bin "*" v (term-sql b))) env)]
                            [(and (quantity? b) (numeric-type? (term-type a))) (quantity-map b (lambda (v) (sql-bin "*" (term-sql a) v)) env)]
                            [(or (quantity? a) (quantity? b)) (untranslatable e "multiplying quantities (unit algebra)")]
                            [else ((binary-arith "*") args rt env e)])))
(def-op! "Divide"
  (lambda (args rt env e)
    (match-define (list a b) args)
    (cond
      [(and (quantity? a) (numeric-type? (term-type b)))
       (term (nonzero-or-null (term-sql b) (term-sql (quantity-map a (lambda (v) (sql-bin "/" (D env 'to-real v) (term-sql b))) env))) 'Quantity)]
      [(and (quantity? a) (quantity? b))
       (term (sql-case (list (cons (sql-or (sql-null-test (term-sql a) #f) (sql-null-test (term-sql b) #f) (sql-bin "=" (qv b env) (sql-lit 0))) sql-null)
                             (cons (sql-bin "=" (qu a env) (qu b env)) (quantity-sql (sql-bin "/" (D env 'to-real (qv a env)) (qv b env)) (sql-lit "1") env)))
                       (D env 'error "dividing quantities in different units (unit algebra)"))
             'Quantity)]
      [(or (quantity? a) (quantity? b)) (untranslatable e "dividing by a quantity")]
      [else (term (nonzero-or-null (term-sql b) (sql-bin "/" (as-real a env) (term-sql b))) 'Decimal)])))

;; same-unit-quantity : (SqlExpr SqlExpr -> SqlExpr) -> OpImpl   div / mod on quantities of one unit
(define (same-unit-quantity f)
  (lambda (a b env e)
    (term (sql-case (list (cons (sql-or (sql-null-test (term-sql a) #f) (sql-null-test (term-sql b) #f) (sql-bin "=" (qv b env) (sql-lit 0))) sql-null)
                          (cons (sql-bin "=" (qu a env) (qu b env)) (quantity-sql (f (D env 'to-real (qv a env)) (D env 'to-real (qv b env))) (qu a env) env)))
                    (D env 'error "quantities in different units"))
          'Quantity)))
(define (trunc-div a b env) (D env 'trunc (sql-bin "/" a b)))
(define (dec-mod a b env) (sql-bin "-" a (sql-bin "*" b (D env 'trunc (sql-bin "/" a b)))))

(def-op! "TruncatedDivide"
  (lambda (args rt env e)
    (match-define (list a b) args)
    (define ty (arith-type args))
    (cond
      [(and (quantity? a) (quantity? b)) ((same-unit-quantity (lambda (x y) (trunc-div x y env))) a b env e)]
      [(not (numeric-type? ty)) (untranslatable e "div on ~a" ty)]
      [else (term (nonzero-or-null (term-sql b)
                                   (if (eq? ty 'Decimal)
                                       (D env 'trunc (sql-bin "/" (as-real a env) (term-sql b)))
                                       (sql-bin "/" (term-sql a) (term-sql b))))
                  ty)])))
(def-op! "Modulo"
  (lambda (args rt env e)
    (match-define (list a b) args)
    (define ty (arith-type args))
    (cond
      [(and (quantity? a) (quantity? b)) ((same-unit-quantity (lambda (x y) (dec-mod x y env))) a b env e)]
      [(not (numeric-type? ty)) (untranslatable e "mod on ~a" ty)]
      [else (term (nonzero-or-null (term-sql b)
                                   (if (eq? ty 'Decimal) (dec-mod (as-real a env) (term-sql b) env) (sql-bin "%" (term-sql a) (term-sql b))))
                  ty)])))
(define (numeric-unary e t)
  (unless (or (numeric-type? (term-type t)) (memq (term-type t) '(Null Quantity))) (untranslatable e "arithmetic on ~a" (term-type t))))
(def-op! "Negate" (lambda (args rt env e)
                    (define t (car args)) (numeric-unary e t)
                    (if (quantity? t) (quantity-map t (lambda (v) (sql-un "-" v)) env)
                        (term (int-guard (sql-un "-" (term-sql t)) (term-type t)) (term-type t)))))
(def-op! "Abs" (lambda (args rt env e)
                 (define t (car args)) (numeric-unary e t)
                 (if (quantity? t) (quantity-map t (lambda (v) (D env 'abs v)) env)
                     (term (int-guard (D env 'abs (term-sql t)) (term-type t)) (term-type t)))))
(define (to-int-op f)
  (lambda (args rt env e)
    (define t (car args)) (numeric-unary e t)
    (define x (f (term-sql t)))
    (term (int-guard (D env 'to-integer x) 'Integer) 'Integer)))
(def-op! "Ceiling" (lambda (args rt env e) ((to-int-op (lambda (x) (D env 'ceil x))) args rt env e)))
(def-op! "Floor" (lambda (args rt env e) ((to-int-op (lambda (x) (D env 'floor x))) args rt env e)))
(def-op! "Truncate" (lambda (args rt env e) ((to-int-op (lambda (x) (D env 'trunc x))) args rt env e)))
(def-op! "Exp" (lambda (args rt env e) (term (D env 'exp (as-real (car args) env)) 'Decimal)))
(def-op! "Ln" (lambda (args rt env e)
                (define x (as-real (car args) env))
                (term (sql-case (list (cons (sql-bin "<=" x (sql-lit 0)) sql-null)) (D env 'ln x)) 'Decimal)))
(def-op! "Log" (lambda (args rt env e)
                 (match-define (list x b) (map (lambda (t) (as-real t env)) args))
                 (term (sql-case (list (cons (sql-or (sql-bin "<=" x (sql-lit 0)) (sql-bin "<=" b (sql-lit 0)) (sql-bin "=" b (sql-lit 1.0))) sql-null))
                                 (sql-bin "/" (D env 'ln x) (D env 'ln b)))
                       'Decimal)))
;; Power: an Integer for integer operands with a known non-negative exponent, else a Decimal
(def-op! "Power"
  (lambda (args rt env e)
    (match-define (list a b) args)
    (define ty (arith-type args))
    (unless (numeric-type? ty) (untranslatable e "Power on ~a" ty))
    (define nonneg-literal?
      (match (elm-nary-operands e)
        [(list _ (elm-literal (or "Integer" "Long") v)) (>= (string->number v) 0)]
        [_ #f]))
    (if (and (memq ty '(Integer Long)) nonneg-literal?)
        (term (int-guard (D env 'to-integer (D env 'power (term-sql a) (term-sql b))) ty) ty)
        (term (D env 'power (as-real a env) (term-sql b)) 'Decimal))))
;; Round(x[, precision]): half away from zero (SQL's round)
(def-op! "Round"
  (lambda (args rt env e)
    (define p (if (pair? (cdr args)) (term-sql (cadr args)) (sql-lit 0)))
    (term (D env 'round (as-real (car args) env) p) 'Decimal)))
(def-op! "Successor"
  (lambda (args rt env e)
    (define t (car args))
    (match (term-type t)
      [(or 'Integer 'Long) (term (int-guard (sql-bin "+" (term-sql t) (sql-lit 1)) (term-type t)) (term-type t))]
      ['Decimal (term (sql-bin "+" (term-sql t) (sql-lit 0.00000001)) 'Decimal)]
      [ty (untranslatable e "Successor of ~a" ty)])))
(def-op! "Predecessor"
  (lambda (args rt env e)
    (define t (car args))
    (match (term-type t)
      [(or 'Integer 'Long) (term (int-guard (sql-bin "-" (term-sql t) (sql-lit 1)) (term-type t)) (term-type t))]
      ['Decimal (term (sql-bin "-" (term-sql t) (sql-lit 0.00000001)) 'Decimal)]
      [ty (untranslatable e "Predecessor of ~a" ty)])))

;; comparison
(define (comparable a b env e)
  (define ty (unify (term-type a) (term-type b)))
  (match ty
    [(or 'Integer 'Long 'Decimal 'String 'Boolean 'Null 'Quantity) ty]
    [(or 'Date 'DateTime 'Time) ty]
    [_ (untranslatable e "comparing ~a values" ty)]))

(define (decimal-key t ty env) (if (eq? ty 'Decimal) (D env 'round (as-real t env) (sql-lit 8)) (term-sql t)))

(define (compare-op sqlop)
  (lambda (args rt env e)
    (match-define (list a b) args)
    (define ty (comparable a b env e))
    (term (cond [(temporal-type? ty) (temporal-compare sqlop (term-sql a) (term-sql b) env)]
                [(eq? ty 'Quantity) (quantity-compare sqlop a b env)]
                [else (sql-bin sqlop (decimal-key a ty env) (decimal-key b ty env))])
          'Boolean)))
(def-op! "Less" (compare-op "<"))
(def-op! "Greater" (compare-op ">"))
(def-op! "LessOrEqual" (compare-op "<="))
(def-op! "GreaterOrEqual" (compare-op ">="))

;; all-equal : (listof SqlExpr) -> SqlExpr   CQL's structural equality over member comparisons:
;; null when any member comparison is null, else true when all are true
(define (all-equal cmps)
  (if (null? cmps) sql-true
      (sql-case (list (cons (apply sql-or (for/list ([c cmps]) (sql-null-test c #f))) sql-null)) (apply sql-and cmps))))

;; first-not-true : (listof SqlExpr) -> SqlExpr   the first comparison that is not true, else true
(define (first-not-true cmps)
  (foldr (lambda (c rest) (sql-case (list (cons (sql-bin "IS" c sql-true) rest)) c)) sql-true cmps))

;; equal-sql : Term Term TEnv ELM -> SqlExpr   CQL `=` (null when either side is null)
(define (equal-sql a b env e)
  (define ty (unify (term-type a) (term-type b)))
  (define either-null (sql-or (sql-null-test (term-sql a) #f) (sql-null-test (term-sql b) #f)))
  (cond
    [(temporal-type? ty) (temporal-compare "=" (term-sql a) (term-sql b) env)]
    [(eq? ty 'Quantity) (quantity-compare "=" a b env)]
    [(tuple-type? ty)
     (define ta (term-type a)) (define tb (term-type b))
     (unless (and (tuple-type? ta) (tuple-type? tb)
                  (equal? (sort (map car (cadr ta)) symbol<?) (sort (map car (cadr tb)) symbol<?)))
       (untranslatable e "comparing tuples of different shapes"))
     ;; members in key order; the first that is not true decides (false or null) — cql/interp's tuple-equal
     (sql-case (list (cons either-null sql-null))
               (first-not-true (for/list ([f (sort (cadr ta) symbol<? #:key car)])
                            (define ft (unify (cdr f) (cdr (assq (car f) (cadr tb)))))
                            (define fa (field a (symbol->string (car f)) ft env))
                            (define fb (field b (symbol->string (car f)) ft env))
                            ;; aligned nulls are equal members (cql/interp's tuple-equal)
                            (sql-case (list (cons (sql-and (sql-null-test (term-sql fa) #f) (sql-null-test (term-sql fb) #f)) sql-true))
                                      (equal-sql fa fb env e)))))]
    [(interval-type? ty)
     (define p (element-type ty))
     (sql-case (list (cons either-null sql-null))
               (all-equal (append (for/list ([k '("low" "high")]) (equal-sql (field a k p env) (field b k p env) env e))
                                  (for/list ([k '("lowClosed" "highClosed")]) (sql-bin "=" (term-sql (field a k 'Boolean env)) (term-sql (field b k 'Boolean env)))))))]
    [(eq? (type-encoding ty) 'json)
     (sql-case (list (cons either-null sql-null))
               (sql-bin "=" (D env 'json-text (term-sql a)) (D env 'json-text (term-sql b))))]
    [else (sql-bin "=" (decimal-key a ty env) (decimal-key b ty env))]))

(def-op! "Equal" (lambda (args rt env e) (term (equal-sql (car args) (cadr args) env e) 'Boolean)))
(def-op! "NotEqual" (lambda (args rt env e) (term (sql-un "NOT" (equal-sql (car args) (cadr args) env e)) 'Boolean)))
;; ~ : null ~ null is true; strings ignore case
(def-op! "Equivalent"
  (lambda (args rt env e)
    (match-define (list a b) args)
    (define ty (unify (term-type a) (term-type b)))
    (define (key t)
      (match ty
        ['String (D env 'lower (term-sql t))]
        ['Decimal (D env 'round (as-real t env) (sql-lit 8))]
        [(? (lambda (ty) (eq? (type-encoding ty) 'json))) (D env 'json-text (term-sql t))]
        [_ (term-sql t)]))
    (when (temporal-type? ty) (untranslatable e "~~ on ~a values" ty))
    (term (if (eq? ty 'Quantity) (quantity-equivalent a b env) (sql-bin "IS" (key a) (key b))) 'Boolean)))

;; logic: SQL's three-valued AND/OR/NOT are CQL's
(def-op! "And" (lambda (args rt env e) (term (sql-bin "AND" (term-sql (car args)) (term-sql (cadr args))) 'Boolean)))
(def-op! "Or" (lambda (args rt env e) (term (sql-bin "OR" (term-sql (car args)) (term-sql (cadr args))) 'Boolean)))
(def-op! "Not" (lambda (args rt env e) (term (sql-un "NOT" (term-sql (car args))) 'Boolean)))
(def-op! "Implies" (lambda (args rt env e) (term (sql-bin "OR" (sql-un "NOT" (term-sql (car args))) (term-sql (cadr args))) 'Boolean)))
(def-op! "Xor" (lambda (args rt env e)
                 (match-define (list a b) (map term-sql args))
                 (term (sql-case (list (cons (sql-or (sql-null-test a #f) (sql-null-test b #f)) sql-null)) (sql-bin "<>" a b)) 'Boolean)))

;; nullology
(def-op! "IsNull" (lambda (args rt env e) (term (sql-null-test (term-sql (car args)) #f) 'Boolean)))
(def-op! "IsTrue" (lambda (args rt env e) (term (sql-bin "IS" (term-sql (car args)) sql-true) 'Boolean)))
(def-op! "IsFalse" (lambda (args rt env e) (term (sql-bin "IS" (term-sql (car args)) sql-false) 'Boolean)))
(def-op! "Coalesce"
  (lambda (args rt env e)
    (cond
      [(and (= (length args) 1) (list-type? (term-type (car args))))
       (define l (car args))
       (term (sql-scalar (select (sql-ref "j" "value") #:from (list (sql-table-fn (D env 'json-each (term-sql l)) "j"))
                                 #:where (sql-null-test (sql-ref "j" "value") #t) #:limit (sql-lit 1)))
             (element-type (term-type l)))]
      [else
       (define ty (foldl unify 'Null (map term-type args)))
       (term (sql-call "coalesce" (map term-sql args)) ty)])))

;; strings
(def-op! "Concatenate"
  (lambda (args rt env e)
    (term (for/fold ([acc (term-sql (car args))]) ([a (cdr args)]) (sql-bin "||" acc (term-sql a))) 'String)))
(def-op! "Upper" (lambda (args rt env e) (term (D env 'upper (term-sql (car args))) 'String)))
(def-op! "Lower" (lambda (args rt env e) (term (D env 'lower (term-sql (car args))) 'String)))
(def-op! "StartsWith"
  (lambda (args rt env e)
    (match-define (list s p) (map term-sql args))
    (term (sql-bin "=" (D env 'substr s (sql-lit 1) (D env 'length p)) p) 'Boolean)))
(def-op! "EndsWith"
  (lambda (args rt env e)
    (match-define (list s p) (map term-sql args))
    (term (sql-case (list (cons (sql-bin "=" (D env 'length p) (sql-lit 0)) (sql-case (list (cons (sql-null-test s #f) sql-null)) sql-true)))
                    (sql-bin "=" (D env 'substr s (sql-un "-" (D env 'length p))) p))
          'Boolean)))
;; Substring(s, start[, length]): 0-based; a start outside the string is null
(def-op! "Substring"
  (lambda (args rt env e)
    (define s (term-sql (car args))) (define start (term-sql (cadr args)))
    (define len (and (pair? (cddr args)) (term-sql (caddr args))))
    (term (sql-case (list (cons (sql-and (sql-bin "=" start (sql-lit 0)) (sql-bin "=" (D env 'length s) (sql-lit 0))) (sql-lit ""))
                          (cons (sql-or (sql-bin "<" start (sql-lit 0)) (sql-bin ">=" start (D env 'length s))) sql-null))
                    (D env 'substr s (sql-bin "+" start (sql-lit 1)) len))
          'String)))
(def-op! "PositionOf"
  (lambda (args rt env e)
    (match-define (list p s) (map term-sql args))
    (term (sql-bin "-" (D env 'instr s p) (sql-lit 1)) 'Integer)))
(def-op! "Combine"
  (lambda (args rt env e)
    (define l (term-sql (car args)))
    (define sep (if (pair? (cdr args)) (term-sql (cadr args)) (sql-lit "")))
    (term (sql-scalar (select (D env 'string-agg (sql-ref "j" "value") sep) #:from (list (sql-table-fn (D env 'json-each l) "j")))) 'String)))

;; Length: a string's characters, a list's elements (null list: 0)
(def-op! "Length"
  (lambda (args rt env e)
    (define t (car args))
    (cond
      [(list-type? (term-type t))
       (term (sql-call "coalesce" (list (D env 'json-length (term-sql t)) (sql-lit 0))) 'Integer)]
      [else (term (D env 'length (term-sql t)) 'Integer)])))

;; Indexer: string character or list element; out of range is null
(def-op! "Indexer"
  (lambda (args rt env e)
    (match-define (list t i) args)
    (cond
      [(list-type? (term-type t))
       (term (sql-case (list (cons (sql-bin "<" (term-sql i) (sql-lit 0)) sql-null))
                       (D env 'json-extract (term-sql t) (sql-bin "||" (sql-bin "||" (sql-lit "$[") (term-sql i)) (sql-lit "]"))))
             (element-type (term-type t)))]
      [else
       (define s (term-sql t))
       (term (sql-case (list (cons (sql-or (sql-bin "<" (term-sql i) (sql-lit 0)) (sql-bin ">=" (term-sql i) (D env 'length s))) sql-null))
                       (D env 'substr s (sql-bin "+" (term-sql i) (sql-lit 1)) (sql-lit 1)))
             'String)])))

;; conversions
(def-op! "ToString"
  (lambda (args rt env e)
    (define t (car args)) (define s (term-sql t))
    (term (match (term-type t)
            ['Boolean (sql-case (list (cons s (sql-lit "true")) (cons (sql-un "NOT" s) (sql-lit "false"))) sql-null)]
            [(or 'String 'Date 'DateTime 'Time) s]
            [(or 'Integer 'Long 'Decimal) (D env 'to-text s)]
            [ty (untranslatable e "ToString of ~a" ty)])
          'String)))
(def-op! "ToInteger"
  (lambda (args rt env e)
    (define t (car args)) (define s (term-sql t))
    (term (match (term-type t)
            [(or 'Integer 'Long) s]
            ['Boolean (sql-case (list (cons s (sql-lit 1)) (cons (sql-un "NOT" s) (sql-lit 0))) sql-null)]
            ['String (sql-case (list (cons (sql-call "glob" (list (sql-lit "[0-9]*") (sql-call "ltrim" (list s (sql-lit "+-")))))
                                           (sql-case (list (cons (sql-call "glob" (list (sql-lit "*[^0-9]*") (sql-call "ltrim" (list s (sql-lit "+-"))))) sql-null))
                                                     (D env 'to-integer s))))
                               sql-null)]
            [ty (untranslatable e "ToInteger of ~a" ty)])
          'Integer)))
(def-op! "ToDecimal"
  (lambda (args rt env e)
    (define t (car args)) (define s (term-sql t))
    (term (match (term-type t)
            [(or 'Integer 'Long 'Decimal) (D env 'to-real s)]
            ['Boolean (sql-case (list (cons s (sql-lit 1.0)) (cons (sql-un "NOT" s) (sql-lit 0.0))) sql-null)]
            ['String (sql-case (list (cons (sql-call "glob" (list (sql-lit "*[^0-9.+-]*") s)) sql-null)
                                     (cons (sql-call "glob" (list (sql-lit "*[0-9]*") s)) (D env 'to-real s)))
                               sql-null)]
            [ty (untranslatable e "ToDecimal of ~a" ty)])
          'Decimal)))
(def-op! "ToBoolean"
  (lambda (args rt env e)
    (define t (car args)) (define s (term-sql t))
    (term (match (term-type t)
            ['Boolean s]
            ['String (let ([l (D env 'lower s)])
                       (sql-case (list (cons (truthy-in l '("true" "t" "yes" "y" "1")) sql-true)
                                       (cons (truthy-in l '("false" "f" "no" "n" "0")) sql-false))
                                 sql-null))]
            [(or 'Integer 'Long) (sql-case (list (cons (sql-bin "=" s (sql-lit 1)) sql-true) (cons (sql-bin "=" s (sql-lit 0)) sql-false)) sql-null)]
            ['Decimal (sql-case (list (cons (sql-bin "=" s (sql-lit 1.0)) sql-true) (cons (sql-bin "=" s (sql-lit 0.0)) sql-false)) sql-null)]
            [ty (untranslatable e "ToBoolean of ~a" ty)])
          'Boolean)))
(define (truthy-in x strs) (apply sql-or (for/list ([s strs]) (sql-bin "=" x (sql-lit s)))))

;; lists (JSON arrays)
(define (each l env alias) (sql-table-fn (D env 'json-each (term-sql l)) alias))
(define (jv alias) (sql-ref alias "value"))

;; exists: any non-null element
(def-op! "Exists"
  (lambda (args rt env e)
    (term (sql-exists (select (sql-lit 1) #:from (list (each (car args) env "j")) #:where (sql-null-test (jv "j") #t))) 'Boolean)))
(def-op! "Count"
  (lambda (args rt env e)
    (term (sql-scalar (select (sql-call "count" (list (jv "j"))) #:from (list (each (car args) env "j")))) 'Integer)))
(define (aggregate sqlfn result)
  (lambda (args rt env e)
    (define l (car args))
    (unless (list-type? (term-type l)) (untranslatable e "~a over a non-list" sqlfn))
    (define el (element-type (term-type l)))
    (unless (or (numeric-type? el) (memq el '(Null String)) (and (temporal-type? el) (member sqlfn '("min" "max"))))
      (untranslatable e "~a over ~a elements" sqlfn el))
    (term (sql-scalar (select (sql-call sqlfn (list (jv "j"))) #:from (list (each l env "j"))))
          (result (element-type (term-type l))))))
(def-op! "Sum"
  (lambda (args rt env e)
    (define l (car args))
    (cond
      [(eq? (element-type (term-type l)) 'Quantity)
       (define v (D env 'json-extract (jv "j") (sql-lit "$.value"))) (define u (D env 'json-extract (jv "j") (sql-lit "$.unit")))
       (term (sql-scalar (select (sql-case (list (cons (sql-bin "=" (sql-call "count" (list (jv "j"))) (sql-lit 0)) sql-null)
                                                 (cons (sql-bin ">" (sql-call "count" (list (sql-call "DISTINCT" (list u)))) (sql-lit 1))
                                                       (D env 'error "Sum of quantities in different units")))
                                           (quantity-sql (sql-call "sum" (list v)) (sql-call "min" (list u)) env))
                                 #:from (list (each l env "j"))))
             'Quantity)]
      [else ((aggregate "sum" values) args rt env e)])))
(def-op! "Min" (aggregate "min" values))
(def-op! "Max" (aggregate "max" values))
(def-op! "Avg" (aggregate "avg" (lambda (_) 'Decimal)))
;; In / Contains: membership, a null element matching a null operand
(define (member-sql x l env)
  (sql-exists (select (sql-lit 1) #:from (list (each l env "j")) #:where (sql-bin "IS" (jv "j") (term-sql x)))))
(def-op! "In" (lambda (args rt env e)
                (match-define (list x l) args)
                (unless (list-type? (term-type l)) (untranslatable e "In over a ~a" (term-type l)))
                (term (member-sql x l env) 'Boolean)))
(def-op! "Contains" (lambda (args rt env e)
                      (match-define (list l x) args)
                      (unless (list-type? (term-type l)) (untranslatable e "Contains over a ~a" (term-type l)))
                      (term (member-sql x l env) 'Boolean)))
(def-op! "First" (lambda (args rt env e) (term (D env 'json-extract (term-sql (car args)) (sql-lit "$[0]")) (element-type (term-type (car args))))))
(def-op! "Last" (lambda (args rt env e) (term (D env 'json-extract (term-sql (car args)) (sql-lit "$[#-1]")) (element-type (term-type (car args))))))
(def-op! "SingletonFrom"
  (lambda (args rt env e)
    (define l (term-sql (car args)))
    (term (sql-case (list (cons (sql-bin ">" (D env 'json-length l) (sql-lit 1)) (D env 'error "SingletonFrom: more than one element")))
                    (D env 'json-extract l (sql-lit "$[0]")))
          (element-type (term-type (car args))))))
(def-op! "Distinct"
  (lambda (args rt env e)
    (define l (car args))
    (define rows (select #:distinct? #t (cons (embed (term (jv "j") (element-type (term-type l))) env) "v") #:from (list (each l env "j"))))
    (term (sql-case (list (cons (sql-null-test (term-sql l) #f) sql-null))
                    (sql-scalar (select (D env 'json-group-array (sql-ref "q" "v")) #:from (list (sql-subquery rows "q")))))
          (term-type l))))
(def-op! "Union"
  (lambda (args rt env e)
    (match-define (list a b) args)
    (unless (and (list-type? (term-type a)) (list-type? (term-type b))) (untranslatable e "Union of non-lists"))
    (define ty (unify (term-type a) (term-type b)))
    (define (rows l alias) (select (cons (embed (term (jv alias) (element-type ty)) env) "v") #:from (list (each l env alias))))
    (term (sql-scalar (select (D env 'json-group-array (sql-ref "q" "v"))
                              #:from (list (sql-subquery (select #:distinct? #t (sql-ref "u" "v") #:from (list (sql-subquery (sql-union-all (list (rows a "a") (rows b "b"))) "u"))) "q"))))
          ty)))

(module+ test
  (require rackunit "sql/print.rkt")
  (define env (make-tenv))
  (define (sql e) (sql->string (term-sql (translate e env))))
  (define (ty e) (term-type (translate e env)))
  (define (lit t v) (elm-literal t v))
  (check-equal? (sql (elm-nary "Add" (list (lit "Integer" "1") (lit "Integer" "2")) "Integer"))
                "CASE WHEN (((1 + 2) < -2147483648) OR ((1 + 2) > 2147483647)) THEN NULL ELSE (1 + 2) END")   ; 32-bit Integer
  (check-equal? (sql (elm-nary "Add" (list (lit "Decimal" "1.5") (lit "Integer" "2")) "Decimal")) "(1.5 + 2)")
  (check-equal? (ty (elm-nary "Divide" (list (lit "Integer" "7") (lit "Integer" "2")) "Decimal")) 'Decimal)
  (check-equal? (ty (elm-list (list (lit "Integer" "1") (lit "Decimal" "2.0")))) '(List Decimal))
  (check-equal? (ty (elm-unary "Abs" (elm-unary "Negate" (lit "Decimal" "1.5") "Decimal") #f)) 'Decimal)
  (check-equal? (sql (elm-date (lit "Integer" "2012") (lit "Integer" "1") (lit "Integer" "5"))) "'2012-01-05'")
  (check-equal? (sql (elm-datetime (lit "Integer" "2012") (lit "Integer" "1") (lit "Integer" "1") (lit "Integer" "10") #f #f #f #f))
                "'2012-01-01T10'")
  (check-equal? (sql (elm-time (lit "Integer" "10") (lit "Integer" "5") #f #f)) "'10:05'")
  (check-exn exn:fail:untranslatable? (lambda () (translate (elm-retrieve "{http://hl7.org/fhir}Condition" #f #f #f #f) env)))
  (check-exn exn:fail:untranslatable? (lambda () (translate (elm-unary "Frobnicate" (lit "Integer" "1") #f) env)))
  (check-true (and (member "Add" (translated-ops)) #t)))
