// BCS-E 16: A woman of 60, continuously enrolled, with a palliative care procedure (SNOMED 103735009) in
// July 2025, during the measurement period: excluded in both groups.

Instance: bcse-16-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-16-member, 1965-06-15, female)

Instance: bcse-16-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-16-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-16-palliative-care
InstanceOf: Procedure
Usage: #example
* insert CompletedProcedure(bcse-16-member, $SCT#103735009 "Palliative care (regime/therapy\)", 2025-07-01)

Instance: bcse-16.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, true, false, false, true, false)

Instance: bcse-16
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 16: palliative care during the period"
* type = #collection
* insert Entry(Patient, bcse-16-member)
* insert Entry(Coverage, bcse-16-coverage)
* insert Entry(Procedure, bcse-16-palliative-care)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-16.scorekey)
