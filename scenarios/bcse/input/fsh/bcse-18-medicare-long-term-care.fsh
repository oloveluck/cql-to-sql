// BCS-E 18: Medicare member in long-term care. A woman of 68, continuously enrolled in a Medicare
// Advantage PPO whose coverage marks her a long-term institutional (LTI) beneficiary, and no
// mammogram. The two groups part here: the all-members group has no long-term-care exclusion, so
// she is in its denominator (and misses its numerator); the Medicare group excludes members 66 or
// older with long-term care, so she is out of the Medicare denominator.

Instance: bcse-18-member
InstanceOf: Patient
Usage: #example
* insert Member(bcse-18-member, 1957-03-01, female)

Instance: bcse-18-coverage
InstanceOf: Coverage
Usage: #example
* insert Enrollment(bcse-18-member, 2023-01-01, 2026-12-31, MP)
* insert LongTermInstitutional

Instance: bcse-18.scorekey
InstanceOf: Parameters
Usage: #example
* insert ScoreKey(true, false, true, false, true, false)

Instance: bcse-18
InstanceOf: Bundle
Usage: #example
Title: "BCS-E 18: Medicare long-term care, excluded from the Medicare group only"
* type = #collection
* insert Entry(Patient, bcse-18-member)
* insert Entry(Coverage, bcse-18-coverage)
* insert Entry(Organization, scenario-payer)
* insert Entry(Parameters, bcse-18.scorekey)
