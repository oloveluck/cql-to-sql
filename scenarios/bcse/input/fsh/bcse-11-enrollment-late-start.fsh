// BCS-E 11: A woman of 60 whose coverage starts 2023-11-01: the last quarter of 2023 must be covered
// with no gap at all, so she is not continuously enrolled and not in the initial population.

Instance: bcse-11-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-11-member, 1965-06-15, female)

Instance: bcse-11-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-11-member, 2023-11-01, 2026-12-31, PPO)

Instance: bcse-11.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(false, false, false, false, false, false)

Instance: bcse-11
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 11: enrolled after the last quarter of 2023 began"
* type = #collection
* insert Entry(Patient, bcse-11-member)
* insert Entry(Coverage, bcse-11-coverage)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-11.scorekey)
