// BCS-E 04: A woman of 60, continuously enrolled, with no mammography record at all. In both
// denominators; not screened (the measure's care gap).

Instance: bcse-04-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-04-member, 1965-06-15, female)

Instance: bcse-04-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-04-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-04.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, false, false, true)

Instance: bcse-04
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 04: eligible, never screened"
* type = #collection
* insert Entry(Patient, bcse-04-member)
* insert Entry(Coverage, bcse-04-coverage)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-04.scorekey)
