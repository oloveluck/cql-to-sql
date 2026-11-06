// BCS-E 01: a screened member. A woman of 60, continuously enrolled in a commercial PPO, with a
// professional claim for a bilateral screening mammogram (CPT 77067) in March 2025.
// In the initial population; no exclusion; in the denominator and the numerator of both groups.

Instance: bcse-01-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-01-member, 1965-06-15, female)

Instance: bcse-01-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-01-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-01-mammogram
InstanceOf: Claim
Usage: #example
* insert ServiceClaim(bcse-01-member, bcse-01-coverage, 2025-03-10, $CPT#77067 "Screening mammography\, bilateral")
* insert ClaimSequences

Instance: bcse-01.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, true, false, true)

Instance: bcse-01
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 01: screened by a mammography claim"
* type = #collection
* insert Entry(Patient, bcse-01-member)
* insert Entry(Coverage, bcse-01-coverage)
* insert Entry(Claim, bcse-01-mammogram)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-01.scorekey)
