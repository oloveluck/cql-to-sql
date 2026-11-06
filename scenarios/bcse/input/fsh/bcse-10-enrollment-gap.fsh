// BCS-E 10: A woman of 60 whose coverage lapses for 61 days in 2025 (2025-04-01 .. 2025-05-31): more than
// the one gap of up to 45 days the current year allows, so not continuously enrolled and not in
// the initial population.

Instance: bcse-10-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-10-member, 1965-06-15, female)

Instance: bcse-10-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-10-member, 2023-01-01, 2025-03-31, PPO)

Instance: bcse-10-coverage-2
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-10-member, 2025-06-01, 2026-12-31, PPO)

Instance: bcse-10.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(false, false, false, false, false, false)

Instance: bcse-10
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 10: a 61-day enrollment gap"
* type = #collection
* insert Entry(Patient, bcse-10-member)
* insert Entry(Coverage, bcse-10-coverage)
* insert Entry(Coverage, bcse-10-coverage-2)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-10.scorekey)
