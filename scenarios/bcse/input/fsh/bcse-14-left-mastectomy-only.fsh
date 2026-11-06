// BCS-E 14: A woman of 60, continuously enrolled, with only a left mastectomy (2012): one side does not
// exclude her. In both denominators; not screened.

Instance: bcse-14-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-14-member, 1965-06-15, female)

Instance: bcse-14-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-14-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-14-left-mastectomy
InstanceOf: Procedure
Usage: #example
* insert CompletedProcedure(bcse-14-member, $ICD10PCS#0HTU0ZZ "Resection of Left Breast\, Open Approach", 2012-04-01)

Instance: bcse-14.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, false, false, true)

Instance: bcse-14
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 14: one mastectomy does not exclude"
* type = #collection
* insert Entry(Patient, bcse-14-member)
* insert Entry(Coverage, bcse-14-coverage)
* insert Entry(Procedure, bcse-14-left-mastectomy)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-14.scorekey)
