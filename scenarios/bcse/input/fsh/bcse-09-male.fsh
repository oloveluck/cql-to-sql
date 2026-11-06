// BCS-E 09: A man of 60, continuously enrolled, with no sex-assigned-at-birth observation and no sex
// parameter for clinical use: not female by any of the measure's three tests, so not in the
// initial population.

Instance: bcse-09-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-09-member, 1965-06-15, male)

Instance: bcse-09-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-09-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-09.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(false, false, false, false, false, false)

Instance: bcse-09
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 09: not female"
* type = #collection
* insert Entry(Patient, bcse-09-member)
* insert Entry(Coverage, bcse-09-coverage)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-09.scorekey)
