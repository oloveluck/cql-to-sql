library BreastScreeningDemo version '1.0.0'

/*
 * A demo measure shaped like HEDIS BCS-E's core: women 42-74 at the end of the measurement period,
 * with a mammogram (a final, amended or corrected Observation in the Mammography value set) during
 * it. Small enough to translate by hand; BCS-E itself adds enrollment, product line and exclusions.
 */

using FHIR version '4.0.1'

include FHIRHelpers version '4.0.001' called FHIRHelpers

valueset "Mammography": 'http://example.org/fhir/ValueSet/demo-mammography'

parameter "Measurement Period" Interval<DateTime>
  default Interval[@2025-01-01T00:00:00.000Z, @2025-12-31T23:59:59.999Z]

context Patient

define "Age at End of Period":
  AgeInYearsAt(date from end of "Measurement Period")

define "Initial Population":
  Patient.gender = 'female'
    and "Age at End of Period" in Interval[42, 74]

define "Denominator":
  "Initial Population"

define "Mammograms During Period":
  [Observation: "Mammography"] O
    where O.status in { 'final', 'amended', 'corrected' }
      and (O.effective as dateTime) during "Measurement Period"

define "Numerator":
  exists "Mammograms During Period"
