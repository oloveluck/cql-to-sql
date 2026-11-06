// BCS-E 02: A woman of 60, continuously enrolled in a commercial PPO, with a mammography claim on
// 2023-10-01, the first day of the 27-month window (successor of 2025-12-31 minus 27 months).
// Screened: in the denominator and the numerator of both groups.

Instance: bcse-02-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-02-member, 1965-06-15, female)

Instance: bcse-02-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-02-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-02-mammogram
InstanceOf: Claim
Usage: #example
* insert ServiceClaim(bcse-02-member, bcse-02-coverage, 2023-10-01, $CPT#77067 "Screening mammography\, bilateral")
* insert ClaimSequences

Instance: bcse-02.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, true, false, true)

Instance: bcse-02
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 02: screened on the first day of the window"
* type = #collection
* insert Entry(Patient, bcse-02-member)
* insert Entry(Coverage, bcse-02-coverage)
* insert Entry(Claim, bcse-02-mammogram)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-02.scorekey)
