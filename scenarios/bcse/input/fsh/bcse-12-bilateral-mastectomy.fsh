// BCS-E 12: bilateral mastectomy. A woman of 60, continuously enrolled, whose EHR records a
// completed bilateral mastectomy (ICD-10-PCS 0HTV0ZZ) in 2010 and no mammogram.
// In the initial population; excluded in both groups (the mastectomy history runs from birth), so
// not in either denominator; not in the numerator.

Instance: bcse-12-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-12-member, 1965-06-15, female)

Instance: bcse-12-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-12-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-12-mastectomy
InstanceOf: Procedure
Usage: #example
* insert CompletedProcedure(bcse-12-member, $ICD10PCS#0HTV0ZZ "Resection of Bilateral Breast\, Open Approach", 2010-05-01)

Instance: bcse-12.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, true, false, false, true, false)

Instance: bcse-12
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 12: excluded by a bilateral mastectomy"
* type = #collection
* insert Entry(Patient, bcse-12-member)
* insert Entry(Coverage, bcse-12-coverage)
* insert Entry(Procedure, bcse-12-mastectomy)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-12.scorekey)
