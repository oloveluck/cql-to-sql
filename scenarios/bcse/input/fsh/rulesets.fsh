// The parts every BCS-E scenario is built from. Dates are for measurement year 2025:
// - continuous enrollment: coverage over 2023-10-01 .. 2025-12-31 (no gap in the last quarter of
//   2023; at most one gap of up to 45 days in 2024 and in 2025)
// - mammography window: 2023-10-01 .. 2025-12-31 (27 months ending the measurement period)
// - age: 42..74 on 2025-12-31
// RuleSet arguments are comma-separated: a comma or a closing parenthesis inside one (a display)
// is written \, or \) (an opening parenthesis needs no escape)

Alias: $CPT = http://www.ama-assn.org/go/cpt
Alias: $ICD10PCS = http://www.cms.gov/Medicare/Coding/ICD10
Alias: $SCT = http://snomed.info/sct
Alias: $DataSource = https://ncqa.org/fhir/CodeSystem/hedis-data-source
Alias: $CoverageType = https://ncqa.org/fhir/CodeSystem/hedis-coverage-type
Alias: $ActCode = http://terminology.hl7.org/CodeSystem/v3-ActCode
Alias: $IdType = http://terminology.hl7.org/CodeSystem/v2-0203
Alias: $ClaimType = http://terminology.hl7.org/CodeSystem/claim-type
Alias: $CoverageClass = http://terminology.hl7.org/CodeSystem/coverage-class
Alias: $Relationship = http://terminology.hl7.org/CodeSystem/subscriber-relationship
Alias: $Priority = http://terminology.hl7.org/CodeSystem/processpriority
Alias: $ObsCategory = http://terminology.hl7.org/CodeSystem/observation-category

// HEDIS resources say where their data came from, and claim their HEDIS core profile. The NCQA
// package ships its profiles without snapshots, which SUSHI needs for `InstanceOf:` a profile, so
// instances are of the base type and claim the profile in meta.profile (as NCQA's own examples
// do); `raco fsh check` validates them against it.
RuleSet: Hedis(source, profile)
* meta.profile[+] = "https://ncqa.org/fhir/StructureDefinition/{profile}"
* meta.tag[+] = $DataSource#{source}
* meta.lastUpdated = "2026-01-15T00:00:00Z"

// HEDIS Patient, Coverage and Organization build on CARIN Blue Button 1.1.0, which requires the
// resource to claim its own profile too (meta.profile's supportedProfile slice)
RuleSet: CarinBlueButton(profile)
* meta.profile[+] = "http://hl7.org/fhir/us/carin-bb/StructureDefinition/{profile}|1.1.0"

// a health plan member
RuleSet: Member(id, birthDate, gender)
* insert Hedis(administrative, hedis-core-patient)
* insert CarinBlueButton(C4BB-Patient)
* identifier[0].type = $IdType#MB "Member Number"
* identifier[0].system = "https://oloveluck.github.io/cql-to-sql/member-id"
* identifier[0].value = "{id}"
* name[0].family = "Scenario"
* name[0].given[0] = "{id}"
* gender = #{gender}
* birthDate = "{birthDate}"

// medical coverage for a member over a period; product is a HEDIS coverage type (PPO commercial,
// MP Medicare Advantage PPO); the second type coding is the medical benefit
RuleSet: Enrollment(member, start, end, product)
* insert Hedis(administrative, hedis-core-coverage)
* insert CarinBlueButton(C4BB-Coverage)
* identifier[0].type = $IdType#MB "Member Number"
* identifier[0].value = "{member}"
* status = #active
* type.coding[0] = $CoverageType#{product}
* type.coding[1] = $ActCode#MCPOL "managed care policy"
* subscriberId = "{member}"
* subscriber = Reference({member})
* beneficiary = Reference({member})
* relationship = $Relationship#self
* period.start = "{start}"
* period.end = "{end}"
* payor[0] = Reference(scenario-payer)
* class[0].type = $CoverageClass#group
* class[0].value = "GROUP1"
* class[0].name = "Scenario group"
* class[1].type = $CoverageClass#plan
* class[1].value = "PLAN1"
* class[1].name = "Scenario plan"

// a professional claim for one service on one day (HEDIS has no profile for a professional
// clinician claim; NCQA's test bundles leave claims unprofiled too)
RuleSet: ServiceClaim(member, coverage, date, code)
* meta.tag[+] = $DataSource#administrative
* meta.lastUpdated = "2026-01-15T00:00:00Z"
* status = #active
* type = $ClaimType#professional
* use = #claim
* patient = Reference({member})
* created = "{date}"
* provider = Reference(scenario-payer)
* priority = $Priority#normal
* insurance[0].focal = true
* insurance[0].coverage = Reference({coverage})
* billablePeriod.start = "{date}"
* billablePeriod.end = "{date}"
* item[0].productOrService = {code}
* item[0].servicedDate = "{date}"

// a claim's sequence numbers. Kept out of ServiceClaim: fsh (as of dae69d0) fails on an integer
// literal inside a parameterized RuleSet (`regexp-replace*: contract violation … given: 1`);
// SUSHI accepts either form. Insert it after ServiceClaim.
RuleSet: ClaimSequences
* insurance[0].sequence = 1
* item[0].sequence = 1

// a completed procedure recorded in the EHR
RuleSet: CompletedProcedure(member, code, date)
* insert Hedis(ehr, hedis-core-procedure)
* status = #completed
* code = {code}
* subject = Reference({member})
* performedDateTime = "{date}"

// what the measure should say about the scenario: each BCS-E population define, by its CQL name,
// for the all-members group and the Medicare group (NCQA's test bundles carry a "scorekey" the same way)
RuleSet: ScoreKey(ip, exclusion, denominator, numerator, exclusionMedicare, denominatorMedicare)
* parameter[+].name = "Initial population"
* parameter[=].valueBoolean = {ip}
* parameter[+].name = "Exclusion"
* parameter[=].valueBoolean = {exclusion}
* parameter[+].name = "Denominator"
* parameter[=].valueBoolean = {denominator}
* parameter[+].name = "Numerator"
* parameter[=].valueBoolean = {numerator}
* parameter[+].name = "Exclusion - Medicare"
* parameter[=].valueBoolean = {exclusionMedicare}
* parameter[+].name = "Denominator - Medicare"
* parameter[=].valueBoolean = {denominatorMedicare}

// a Bundle entry for an instance of this project
RuleSet: Entry(type, id)
* entry[+].fullUrl = "https://oloveluck.github.io/cql-to-sql/bcse-scenarios/{type}/{id}"
* entry[=].resource = {id}

// marks a coverage's member a long-term institutional (LTI) beneficiary
RuleSet: LongTermInstitutional
* extension[+].url = "https://ncqa.org/fhir/StructureDefinition/ext-coverage.lti"
* extension[=].valueBoolean = true

// the plan every scenario's coverage is with
Instance: scenario-payer
InstanceOf: Organization
Usage: #example
Title: "Scenario health plan"
* insert Hedis(administrative, hedis-core-organization)
* insert CarinBlueButton(C4BB-Organization)
* identifier[0].system = "http://hl7.org/fhir/sid/us-npi"
* identifier[0].value = "1234567893"
* active = true
* name = "Scenario Health Plan"
