# Demo: evaluating a real quality measure over a population

```sh
racket demo/bcse/run.rkt
```

## What a quality measure is

A quality measure asks one question of a population. For NCQA's **Breast Cancer Screening (BCS-E)**,
a HEDIS measure health plans report on: *of the women who should be screened for breast cancer, how
many were?*

Every member goes through the same funnel:

1. **Eligible?** A woman aged 42–74 at the end of the year, continuously enrolled in a health plan
   with medical coverage (commercial, Medicare, Medicaid or an exchange plan). This is the
   *initial population*.
2. **Excused?** Screening does not apply to someone who has had both breasts removed, is in hospice
   or palliative care, died during the year, or is 66 or older with an advanced illness and frailty.
   These are the *exclusions*.
3. **Accountable:** whoever is eligible and not excused. This is the *denominator*: the people the
   plan is answerable for.
4. **Screened?** A mammogram between October 2023 and the end of 2025. This is the *numerator*.

The **rate** is screened ÷ accountable. Medicare plans report a second group, which also excuses
members 66 and older living long-term in an institution.

## What "evaluating the measure" means

The measure is published as computable logic, not prose: a FHIR **Measure** (which populations
there are and how they are scored) and **Libraries** of CQL (the exact rule for each population,
down to which codes count as a mammogram). Evaluating it means running that logic over each
member's health records (enrollment, claims, procedures, observations) for a measurement period, and
writing the result as a FHIR **MeasureReport**: one per member saying where they landed, and a
summary with the counts and the rate.

Here the logic is NCQA's own, unmodified: `BCSE_Details` and the 42 shared HEDIS libraries it uses
(`BCSE_Details-2025.3.0.bundle.json`). The cql interpreter runs it.

## The members

19 synthetic members (`scenarios/bcse/`), each a small story that takes one path through the funnel:
screened by a claim, screened by a lab result, a mammogram one day too early, never screened, too
young, too old, not female, a gap in enrollment, a bilateral mastectomy, one mastectomy only,
hospice, palliative care, deceased, Medicare long-term care, … Each member's records are FHIR
resources written in FSH and checked against NCQA's HEDIS profiles, and each carries the result we
expect, worked out by hand from the measure's rules.

The demo prints the funnel, one row per member, then the totals:

```
                            eligible  excused  accountable  screened  rate
All members                       14        5            9         4  44.4%
Medicare reporting group          14        6            8         4  50.0%

The measure's result matches the expected result for 19 of 19 members.
```

and writes the MeasureReports to `demo/out/bcse/` (`summary.json`, and `bcse-NN.json` per member).

**Caveats.** The members are synthetic, one per path, so the rate says nothing clinical. The code
lists are TEST-ONLY stand-ins at NCQA's value set urls (NCQA's Value Set Directory is licensed
separately), holding the codes the members use: a test of the logic, not a HEDIS rate.

## The same measure over 1,000 members

```sh
racket demo/bcse/population.rkt
```

`bcse_usqc_testdata_n1000.zip` (repo root) is a synthetic population of 1,000 members: a FHIR Bulk
Data export on the US Quality Core 0.5.0 profiles, with an answer key giving each member's expected
populations, written from the generator's scenario design. The demo runs NCQA's measure over every
member (about 30 seconds) and compares it with the key:

```
                                    NCQA logic  answer key
members                                   1000        1000
eligible (initial population)              409         408
excused (exclusions)                        20          24
accountable (denominator)                  389         384
screened (numerator)                       141         234
rate                                     36.2%       60.9%

The measure agrees with the answer key on 894 of 1000 members.
```

Every one of the other 106 is explained, and the demo prints the cause for each:

| Members | Cause |
|---|---|
| 91 | **The mammogram is recorded only as a Procedure.** NCQA's digital measure reads screening from claims, EOBs, Observations and DiagnosticReports; this export records most mammograms as a Procedure, the eCQM convention. This is the whole difference in the rate. |
| 6 | **The answer key's rules differ from MY2025 BCS-E.** It excludes two unilateral mastectomies 14+ days apart (no such rule now) and frailty on one date (NCQA needs two), and it leaves out two members whose own sex-at-birth record qualifies them. |
| 6 | **The measure doesn't read some status fields.** A cancelled Coverage still counts as enrollment, a refuted diagnosis still excludes, and hospice that was only ordered (a ServiceRequest) doesn't count. |
| 3 | **A cql bug.** `Quantity.value` and `.unit` come back null, so an allowed 30-day coverage gap fails continuous enrollment. |

So the same measure, run over the same people, gives a very different rate depending on how the
data records care. That is what evaluating a measure tests.

**The adapter.** Before evaluation each Coverage is mapped the way a health plan's HEDIS load would
map it, and nothing else is changed:
- The NAHDO payer type also gets the HEDIS coverage type and the medical benefit, because NCQA finds
  the product line through a fixed table of HEDIS codes.
- An open-ended coverage ends on the export's date, because in CQL a closed interval with a null end
  has an *unknown* end.

The MeasureReports go to `demo/out/bcse-population/`: `summary.json`, and `individual.ndjson` with
one per member. `raco test demo/bcse/population.rkt` checks that every difference has a known cause
and that at least 894 members agree.

## How it runs

- **Members:** fsh compiles the scenarios and validates them against the HEDIS profiles.
- **Logic:** cql parses and compiles the 43 libraries. For each member, `load-runtime-library`
  binds the member's records, the value sets and the measurement period (2025), and `rlib-value`
  evaluates the population definitions.
- **Reports:** `measure-report` (cql/measure) turns the populations into MeasureReports.
  - It uses FHIR's population rules: the denominator holds the eligible members, the exclusions
    are a part of it, and they are subtracted for the score.
  - NCQA's `"Denominator"` definition already leaves the excluded out. So an evaluator that counts
    the Measure's own criteria by those rules reports no exclusions, though with the same rate.
  - The demo therefore counts the exclusions from the `"Exclusion"` definitions.
- **The same with SQL:** `demo/run.rkt` shows a simplified version of this measure giving identical
  MeasureReports from the CQL interpreter and from SQL over SQL-on-FHIR views, which is where
  cql-to-sql is headed for BCS-E itself.

**Setup:**
- `racket scripts/install-hedis.rkt`, after one `sushi build scenarios/bcse` so its dependencies are
  cached. This puts the HEDIS packages where fsh finds them.
- A cql recent enough to compile NCQA's libraries and export `measure-report` (upstream `29b6bf8`
  or later). With an older one the demo says how many libraries compile and stops. With an
  up-to-date checkout elsewhere: `racket -S <its parent directory> demo/bcse/run.rkt`.

`raco test demo/bcse/run.rkt` checks that every member matches and the totals are 14 / 5 / 4. Note
that `raco test` runs each file in a fresh process, so with an up-to-date cql elsewhere, pass it as
`PLTCOLLECTS="<its parent directory>:" raco test …` rather than with `-S`.
