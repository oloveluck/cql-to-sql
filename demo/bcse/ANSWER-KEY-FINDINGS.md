# BCS-E test population: findings for the data's author

For whoever generated `bcse_usqc_testdata_n1000` (`generate.py`, `answer_key_bcse_my2025.csv`).

We ran NCQA's own BCS-E logic over the population: `BCSE_Details` 2025.3.0 and its 42 libraries,
unmodified, with NCQA's MY2025 value sets (`2025.3.0.zip`). We compared it member by member with the
answer key:
- **As delivered:** 892 of 1,000 members agree on every population.
- **With the mammography Procedures also sent as results** (below): 983 agree.

Every other difference is traced below to its records and to the rule in NCQA's CQL.

To see any member yourself:
- `racket demo/bcse/population.rkt <member ids>` prints the member's records, both results, and the
  evidence the measure used.
- The interactive report (`demo/out/bcse-population/report.html`) lists all of them.

## Suggested fixes to the answer key or the generator

### 1. Sex assigned at birth is ignored (2 members)
The key's own rule says "administrative gender female, or sex assigned at birth female", and NCQA's
logic is the same. These members have gender `unknown`, a final LOINC 76689-9 Observation valued
LA3-6 (female), and the right age and enrollment. The key leaves their `sex_assigned_at_birth` empty
and marks them not eligible.

| Member | Record |
|---|---|
| bcse-0137 | Observation LOINC 76689-9 (Sex assigned at birth) = LA3-6 female, 1975-06-18 |
| bcse-0217 | Observation LOINC 76689-9 (Sex assigned at birth) = LA3-6 female, 1956-12-19 |

**Fix:** derive the key's sex-at-birth column from the Observations the generator writes, or stop
writing those Observations for "routine" members.

### 2. Two unilateral mastectomies 14+ days apart (EXC-06, 2 members)
MY2025 BCS-E has no such rule. In `BCSE_Details`, a pair of unilateral mastectomies excludes only
when the sides are known:
- a unilateral mastectomy with a bilateral modifier;
- left plus right, from modifiers, from Clinical Unilateral Mastectomy with a laterality body site, or
  from the Unilateral Mastectomy Left/Right value sets;
- or a history or absence of both breasts.

These members have two CPT 19303 procedures (2021-03-01 and 2021-03-31) with no laterality, so they
stay in the denominator. bcse-0072 and bcse-0073 are both EXC-06.

**Fix:** expect "not excluded" for EXC-06. Or, to test the exclusion, give the procedures modifiers
`LT` and `RT` (or a left and a right body site).

### 3. Frailty on one date (EXC-16, 2 members)
NCQA's frailty test (`Has frailty during measurement period` in the Cache library) needs frailty
indications on **at least two distinct dates** in the measurement year. These members have one:
Condition R54 on 2025-02-01. NCQA also classes R54 as a frailty *symptom* (value set Frailty
Symptom), not a frailty diagnosis.

**Fix:** add a second frailty indication on another 2025 date, or expect "not excluded". The two
heart-failure visits do satisfy the advanced-illness half.

### 4. Gender dysphoria coded F64.0 (EXC-19, 2 members)
The gender-affirming chest surgery exclusion needs a gender dysphoria diagnosis from NCQA's Gender
Dysphoria value set: F64.1, F64.2, F64.8, F64.9, Z87.890. **F64.0 is not in it**, so bcse-0098 and
bcse-0099 are not excluded. Their surgery (CPT 19318, 2022-08-03) is found.

**Fix:** code the dysphoria with one of the codes above.

### 5. Mammograms recorded only as a Procedure (91 members)
This is the main difference between the two rates: 36.1% from NCQA's logic as delivered, against 60.9%
in the key.
- BCS-E's numerator reads mammograms from Claims, EOBs, Observations and DiagnosticReports.
- It never reads Procedure.
- 91 members' mammograms exist only as a Procedure, the eCQM / US Quality Core convention. For
  example, bcse-0128 has Procedure CPT 77067 on 2024-12-01.

**Fix (recommended):** record screening the way HEDIS data carries it: a professional claim with the
CPT code (administrative data), or a final Observation or DiagnosticReport (supplemental clinical
data). Our what-if does the second (`racket demo/bcse/population.rkt --supplemental`), and the rate
becomes 60.4% against the key's 60.9%.

If the Procedure convention is intended, the matching measure is CMS's eCQM (CMS125), which reads
Procedure, rather than HEDIS BCS-E.

## For information: what the measure does not read (6 members)
These follow NCQA's logic as written, so the key's expectation is reasonable clinically but not what
MY2025 computes:
- **A cancelled Coverage still counts as enrollment** (ENR-05, bcse-0111 and bcse-0112). The
  enrollment logic reads `Coverage.period`, not `status`.
- **A refuted diagnosis still excludes** (EXC-10, bcse-0080 and bcse-0081: Z90.13 with
  verificationStatus refuted). The conditions logic does not read `verificationStatus`.
- **Hospice only ordered does not count** (EXC-13, bcse-0086 and bcse-0087: ServiceRequest SNOMED
  385763009). The measure reads hospice from claims, encounters and procedures, not ServiceRequest.

## One difference is ours
**3 members (ENR-01, a 30-day coverage gap) fail continuous enrollment because of a bug in our cql
interpreter.** `Quantity.value` and `.unit` return null, so an allowed gap is not recognized. The key
is right there; the fix is in the interpreter.
