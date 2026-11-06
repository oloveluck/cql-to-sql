// BCS-E 03: A woman of 60, continuously enrolled, whose only mammography claim is on 2023-09-30, one day
// before the 27-month window opens. In both denominators; not screened.

Instance: bcse-03-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-03-member, 1965-06-15, female)

Instance: bcse-03-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-03-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-03-mammogram
InstanceOf: Claim
Usage: #example
* insert ServiceClaim(bcse-03-member, bcse-03-coverage, 2023-09-30, $CPT#77067 "Screening mammography\, bilateral")
* insert ClaimSequences

Instance: bcse-03.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, false, false, true)

Instance: bcse-03
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 03: a mammogram one day before the window"
* type = #collection
* insert Entry(Patient, bcse-03-member)
* insert Entry(Coverage, bcse-03-coverage)
* insert Entry(Claim, bcse-03-mammogram)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-03.scorekey)
