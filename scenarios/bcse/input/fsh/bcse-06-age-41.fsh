// BCS-E 06: A woman who is 41 on 2025-12-31 (born 1984-06-15), continuously enrolled: below the 42..74
// age range, so not in the initial population of either group.

Instance: bcse-06-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-06-member, 1984-06-15, female)

Instance: bcse-06-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-06-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-06.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(false, false, false, false, false, false)

Instance: bcse-06
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 06: too young (41)"
* type = #collection
* insert Entry(Patient, bcse-06-member)
* insert Entry(Coverage, bcse-06-coverage)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-06.scorekey)
