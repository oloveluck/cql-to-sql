// BCS-E 05: A woman of 60, continuously enrolled, whose screening mammogram is recorded in the EHR as a
// final Observation (2025-02-01) rather than a claim. Screened through the Observation path.

Instance: bcse-05-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-05-member, 1965-06-15, female)

Instance: bcse-05-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-05-member, 2023-01-01, 2026-12-31, PPO)

Instance: bcse-05-mammogram
InstanceOf: Observation
Usage: #example
* insert Hedis(ehr, hedis-core-observation)
* status = #final
* category = $ObsCategory#procedure "Procedure"
* code = $CPT#77067 "Screening mammography, bilateral"
* subject = Reference(bcse-05-member)
* effectiveDateTime = "2025-02-01"

Instance: bcse-05.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, true, false, true)

Instance: bcse-05
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 05: screened, recorded as an Observation"
* type = #collection
* insert Entry(Patient, bcse-05-member)
* insert Entry(Coverage, bcse-05-coverage)
* insert Entry(Observation, bcse-05-mammogram)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-05.scorekey)
