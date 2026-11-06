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

**Caveats.** The members are synthetic, one per path, so the rate says nothing clinical. The value
sets are NCQA's own MY2025 expansions (`2025.3.0.zip`, read by `scripts/ncqa-valuesets.rkt`); without
that zip the TEST-ONLY stand-ins (`scripts/standin-valuesets.rkt`) take their place.

## The same measure over 1,000 members

```sh
racket demo/bcse/population.rkt
racket demo/bcse/population.rkt --supplemental   # the what-if below
```

`bcse_usqc_testdata_n1000.zip` (repo root) is a synthetic population of 1,000 members: a FHIR Bulk
Data export on the US Quality Core 0.5.0 profiles, with an answer key giving each member's expected
populations, written from the generator's scenario design. The demo runs NCQA's measure, with NCQA's
value sets, over every member (about 40 seconds) and compares it with the key:

```
                                      NCQA logic  + supplemental      answer key
eligible (initial population)                409             409             408
excused (exclusions)                          18              18              24
accountable (denominator)                    391             391             384
screened (numerator)                         141             236             234
rate                                       36.1%           60.4%           60.9%

As delivered, the measure agrees with the answer key on 892 of 1000 members; with the supplemental feed, 983.
```

Every one of the other 108 is explained, and the demo prints the cause for each:

| Members | Cause |
|---|---|
| 91 | **The mammogram is recorded only as a Procedure.** NCQA's digital measure reads screening from claims, EOBs, Observations and DiagnosticReports; this export records most mammograms as a Procedure, the eCQM convention. This is the whole difference in the rate. |
| 6 | **The answer key's rules differ from MY2025 BCS-E.** It excludes two unilateral mastectomies 14+ days apart (no such rule now) and frailty on one date (NCQA needs two), and it leaves out two members whose own sex-at-birth record qualifies them. |
| 2 | **A code NCQA's set doesn't hold.** The gender dysphoria diagnosis is coded F64.0, which NCQA's Gender Dysphoria value set does not contain. |
| 6 | **The measure doesn't read some status fields.** A cancelled Coverage still counts as enrollment, a refuted diagnosis still excludes, and hospice that was only ordered (a ServiceRequest) doesn't count. |
| 3 | **A cql bug.** `Quantity.value` and `.unit` come back null, so an allowed 30-day coverage gap fails continuous enrollment. |

So the same measure, run over the same people, gives a very different rate depending on how the
data records care. That is what evaluating a measure tests. `ANSWER-KEY-FINDINGS.md` writes these up,
with the records, for the data's author.

**The what-if: a supplemental data feed.** With `--supplemental`, each completed Procedure whose code
is in NCQA's Mammography value set also appears as a final Observation (same code and date), the
way a plan sends clinical data to HEDIS as supplemental data. This is a data transformation, not
NCQA's rule, and the default run reads the data as delivered. It closes the gap: 60.4% against the
key's 60.9%, and 983 members agree. The proper fix is in the data: record screening as a claim or a
result.

**The adapter.** Before evaluation each Coverage is mapped the way a health plan's HEDIS load would
map it, and nothing else is changed:
- The NAHDO payer type also gets the HEDIS coverage type and the medical benefit, because NCQA finds
  the product line through a fixed table of HEDIS codes.
- An open-ended coverage ends on the export's date, because in CQL a closed interval with a null end
  has an *unknown* end.

**Why each member landed where they did.** NCQA tags the defines that hold the evidence for each
population (`@supportingEvidence` in BCSE_Details). `evidence.rkt` reads those tags from the
measure's own CQL, evaluates each define for the member, and renders the records it holds, one line
each: type, code, date. For a difference, the demo also points at the record it turns on, including
records the measure never reads.

```sh
racket demo/bcse/population.rkt bcse-0092 bcse-0001     # these members, with their evidence
```
```
bcse-0092  Age 70, frailty diagnosis + advanced illness (two outpatient visits with CHF): excluded  [EXC-16]
  NCQA logic: not screened    answer key: excused
  why they differ: key: frailty on one date
    NCQA's frailty needs indications on at least two dates in the measurement year; the member has one
    the record: Condition e241471d…: ICD-10-CM R54 (Age-related physical debility), 2025-02-01
  evidence the measure found
    eligible
      Eligible coverages with continuous enrollment
        Coverage 1127ed25…: SOPT 5 (PRIVATE HEALTH INSURANCE); HEDIS coverage PPO (Commercial PPO); …
    excused
      Frailty Event conditions during measurement period for persons 66 years and older
        Condition e241471d…: ICD-10-CM R54 (Age-related physical debility), 2025-02-01
      Advanced Illness Event conditions during measurement period or year prior for persons 66 years and older
        Condition e45ae45e…: ICD-10-CM I50.9 (Heart failure, unspecified), 2025-03-12
        Condition 4b94eb7e…: ICD-10-CM I50.9 (Heart failure, unspecified), 2024-11-05
```

**The interactive report.** A full run also writes `demo/out/bcse-population/report.html`, a
single page with everything inlined:
- the funnel against the answer key;
- the causes, each a filter;
- every member, searchable and filterable by outcome or by agreement, with the selected member's
  outcomes, cause, the records it turns on, and the evidence trail.

`#bcse-0092` in the address opens that member. The page is filled from `report-template.html`.

The MeasureReports go to `demo/out/bcse-population/`: `summary.json`, and `individual.ndjson` with
one per member. `raco test demo/bcse/population.rkt` checks:
- every difference has a known cause;
- at least 892 members agree (983 with the supplemental feed);
- every excused member has exclusion evidence, and every screened member a mammography record.

## Through a FHIR server

```sh
racket demo/bcse/server.rkt                # load the store once, then $evaluate-measure
racket demo/bcse/server.rkt --serve 8080   # … and keep the server up for curl or a browser
```

The same measure, the way a measure-calculation service runs it.
- **The server.** `fhir-server` (in `../fhir`) is a SQLite FHIR store behind the CQF Measures
  guide's measure-calculation-service CapabilityStatement. Its `$evaluate-measure` is cql/measure
  over the store.
- **Loading.** Everything goes in through the server's own transaction endpoint (`POST /`):
  - the Measure and its 43 Libraries;
  - NCQA's 167 ValueSets that BCS-E declares;
  - the population's 11,770 resources, after the Coverage adapter.

  Each resource is indexed for search, so the first load takes a while. The store is kept in
  `demo/out/bcse-server.db` and reused; `--fresh` reloads it.
- **Evaluating.** `GET /Measure/BCSE-Details/$evaluate-measure?periodStart=2025-01-01&periodEnd=2025-12-31`
  returns the summary MeasureReport, and `&subject=Patient/bcse-0092` one member's.
- **The check.** The script compares the server's counts with the in-memory run (`population.rkt`).
  The server applies FHIR's population rules to the Measure's own criteria, so it reports no
  exclusions: NCQA's `"Denominator"` already leaves the excused out. Its denominator is the
  accountable members, and the rate is the same.

Run it with an up-to-date cql, and keep compiled files out of the fhir and cql checkouts:
`PLTCOLLECTS="<cql checkout's parent>:" PLTCOMPILEDROOTS="<scratch dir>:same" racket demo/bcse/server.rkt`.

## The animated walkthrough

`racket demo/bcse/population.rkt` also writes `demo/out/bcse-population/walkthrough.html` from
`walkthrough-template.html`. It follows five real members, step by step:
1. their records in the FHIR store;
2. the engine retrieving them;
3. the three checks, each with the evidence it used;
4. the MeasureReport;
5. the answer key.

The members:
- one screened by a claim;
- one screened only on a Procedure;
- one too young;
- one excused by a bilateral mastectomy;
- the one-date frailty case.

Then all 1,000 members fall through the funnel. It has Play, Next and Back, the arrow keys work, and
with reduced motion it shows each end state.

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
