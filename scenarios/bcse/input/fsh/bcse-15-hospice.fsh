// BCS-E 15: A woman of 60, continuously enrolled, with a hospice care procedure (SNOMED 385763009) in
// August 2025, during the measurement period: excluded in both groups.

Instance: bcse-15-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-15-member, 1965-06-15, female)

Instance: bcse-15-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-15-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-15-hospice
InstanceOf: Procedure
Usage: #example
* insert CompletedProcedure(bcse-15-member, $SCT#385763009 "Hospice care (regime/therapy\)", 2025-08-01)

Instance: bcse-15.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, true, false, false, true, false)

Instance: bcse-15
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 15: hospice during the period"
* type = #collection
* insert Entry(Patient, bcse-15-member)
* insert Entry(Coverage, bcse-15-coverage)
* insert Entry(Procedure, bcse-15-hospice)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-15.scorekey)
