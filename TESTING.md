# Testing cql-to-sql

The translator is checked against the CQL interpreter of the [`cql`](https://github.com/oloveluck/cql)
package, which is itself held to HL7's CQL suite. A check passes when the SQL gives the same value,
or the same MeasureReport, as the interpreter. Floors only rise.

## What is verified

| Check | Test | Last recorded result |
|---|---|---|
| each expression of the HL7 CQL suite, translated, run in SQLite and compared with the expected value as the interpreter evaluates it | `tests/tck-test.rkt` | 902 pass, 4 known failures, 875 untranslatable, 42 skipped |
| the demo measure: the generated SQL and the hand-written `demo/BreastScreeningDemo.sql`, each over 12 patients, give MeasureReports identical to the interpreter's | `library.rkt`'s tests, `demo/run.rkt` | 13 of 13 identical (12 individual and the summary) |
| the relational model (`model/`): it covers every element BCS-E reads, the R4 → R6 conversion is lossless, and every column equals an independent walk of the data | `tests/model-test.rkt` | 309/309 columns on each of three corpora |
| the 19 BCS-E scenarios build, validate against the HEDIS profiles, and the **interpreter** agrees with every score key | `tests/bcse-scenarios-test.rkt` | 19/19, interpreter only |

The 4 known failures are Decimal precision: SQLite's `REAL` is a double, where a CQL Decimal has 28
digits and keeps its lexeme's precision. They are pinned by name in `tests/tck-test.rkt`, and any
other failure fails the test. An untranslatable expression raises `exn:fail:untranslatable`; the
translator never emits SQL that computes something else.

## What is not verified

- **No real measure has been translated.** HEDIS BCS-E runs in the interpreter (`demo/bcse/`), not in
  SQL, and the eCQM corpus is not yet a SQL oracle.
- **The translator and the relational model are not connected.** The translator writes SQL against
  the demo's two hand-written views; the 86 generated views in `model/views/` use a different shape.
- **Only SQLite is run.** The DuckDB dialect prints but no test executes it, and there is no
  PostgreSQL dialect.
- **Coverage.** The most common untranslatable constructs are timing phrases with a precision and
  `overlaps`, `between` over non-intervals, interval set operations, the `aggregate` clause, `Today`
  and `ToDateTime`. A retrieve filtered by a single Code, not a value set, is translated without its
  code filter. [docs/translation.md](docs/translation.md#known-limits) lists the limits in full.

## Running them

```sh
raco test -p cql-to-sql      # everything; the BCS-E scenario checks need fsh and a SUSHI build
racket tests/tck.rkt -v      # the SQL TCK report, with the untranslatable constructs counted
racket demo/run.rkt          # the demo, both ways
```

`tests/bcse-scenarios-test.rkt` needs the `fsh` package and the HEDIS package steps in
`demo/bcse/README.md`.
