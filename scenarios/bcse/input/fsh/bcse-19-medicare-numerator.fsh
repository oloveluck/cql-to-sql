// BCS-E 19: A woman of 70 in a Medicare Advantage PPO, continuously enrolled, not in long-term care, with
// a mammography claim in 2024: screened in both groups (the Medicare group's extra exclusion does
// not apply).

Instance: bcse-19-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-19-member, 1955-05-20, female)

Instance: bcse-19-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-19-member, 2023-01-01, 2026-12-31, MP)

Instance: bcse-19-mammogram
InstanceOf: Claim
Usage: #example
* insert ServiceClaim(bcse-19-member, bcse-19-coverage, 2024-11-12, $CPT#77067 "Screening mammography\, bilateral")
* insert ClaimSequences

Instance: bcse-19.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, true, false, true)

Instance: bcse-19
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 19: a screened Medicare member"
* type = #collection
* insert Entry(Patient, bcse-19-member)
* insert Entry(Coverage, bcse-19-coverage)
* insert Entry(Claim, bcse-19-mammogram)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-19.scorekey)
