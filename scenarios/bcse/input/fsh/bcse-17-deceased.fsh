// BCS-E 17: A woman of 60, continuously enrolled, who died on 2025-09-01, during the measurement period:
// excluded in both groups.

Instance: bcse-17-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-17-member, 1965-06-15, female)
* deceasedDateTime = "2025-09-01"

Instance: bcse-17-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-17-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-17.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, true, false, false, true, false)

Instance: bcse-17
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 17: deceased during the period"
* type = #collection
* insert Entry(Patient, bcse-17-member)
* insert Entry(Coverage, bcse-17-coverage)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-17.scorekey)
