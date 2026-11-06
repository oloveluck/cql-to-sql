// BCS-E 08: A woman who is 75 on 2025-12-31 (born 1950-06-15): above the 42..74 age range, so not in
// the initial population of either group.

Instance: bcse-08-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-08-member, 1950-06-15, female)

Instance: bcse-08-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-08-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-08.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(false, false, false, false, false, false)

Instance: bcse-08
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 08: too old (75)"
* type = #collection
* insert Entry(Patient, bcse-08-member)
* insert Entry(Coverage, bcse-08-coverage)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-08.scorekey)
