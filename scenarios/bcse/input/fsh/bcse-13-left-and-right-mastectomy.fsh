// BCS-E 13: A woman of 60, continuously enrolled, with a left mastectomy (ICD-10-PCS 0HTU0ZZ, 2012) and a
// right mastectomy (0HTT0ZZ, 2018): together they count as bilateral, so she is excluded in both
// groups.

Instance: bcse-13-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-13-member, 1965-06-15, female)

Instance: bcse-13-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-13-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-13-left-mastectomy
InstanceOf: Procedure
Usage: #example
* insert CompletedProcedure(bcse-13-member, $ICD10PCS#0HTU0ZZ "Resection of Left Breast\, Open Approach", 2012-04-01)

Instance: bcse-13-right-mastectomy
InstanceOf: Procedure
Usage: #example
* insert CompletedProcedure(bcse-13-member, $ICD10PCS#0HTT0ZZ "Resection of Right Breast\, Open Approach", 2018-09-01)

Instance: bcse-13.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, true, false, false, true, false)

Instance: bcse-13
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 13: left and right mastectomies"
* type = #collection
* insert Entry(Patient, bcse-13-member)
* insert Entry(Coverage, bcse-13-coverage)
* insert Entry(Procedure, bcse-13-left-mastectomy)
* insert Entry(Procedure, bcse-13-right-mastectomy)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-13.scorekey)
