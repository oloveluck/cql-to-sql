// BCS-E 07: A woman born 1983-12-31, so exactly 42 on 2025-12-31, the last day of the measurement period:
// the youngest age in range. In both denominators; not screened.

Instance: bcse-07-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-07-member, 1983-12-31, female)

Instance: bcse-07-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-07-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-07.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, false, false, true)

Instance: bcse-07
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 07: 42 on the last day of the period"
* type = #collection
* insert Entry(Patient, bcse-07-member)
* insert Entry(Coverage, bcse-07-coverage)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-07.scorekey)
