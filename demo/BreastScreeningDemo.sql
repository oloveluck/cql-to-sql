-- BreastScreeningDemo.cql as SQL (SQLite) over the demo's ViewDefinition tables: one row per
-- patient, a column per population, the proportion-scoring subset rules applied.
--
-- Written by hand in the shape the translator is to generate: a CTE per define, the measurement
-- period as parameters (:period_start, :period_end), the value set as the valueset_code table.
--
-- Tables: patient(id, gender, birth_date), observation(id, patient_id, status, effective,
-- code_system, code) — one row per coding — and valueset_code(url, system, code).

WITH
-- define "Age at End of Period": AgeInYearsAt(date from end of "Measurement Period")
age_at_end_of_period AS (
  SELECT p.id AS patient_id,
         CAST(strftime('%Y', :period_end) AS INTEGER) - CAST(strftime('%Y', p.birth_date) AS INTEGER)
           - (strftime('%m-%d', :period_end) < strftime('%m-%d', p.birth_date)) AS age
  FROM patient p
),
-- define "Initial Population": Patient.gender = 'female' and "Age at End of Period" in Interval[42, 74]
initial_population AS (
  SELECT p.id AS patient_id,
         COALESCE(p.gender = 'female' AND a.age BETWEEN 42 AND 74, 0) AS v
  FROM patient p JOIN age_at_end_of_period a ON a.patient_id = p.id
),
-- define "Mammograms During Period": [Observation: "Mammography"] O
--   where O.status in { 'final', 'amended', 'corrected' } and (O.effective as dateTime) during "Measurement Period"
mammograms_during_period AS (
  SELECT DISTINCT o.patient_id, o.id
  FROM observation o
  JOIN valueset_code vs
    ON vs.url = 'http://example.org/fhir/ValueSet/demo-mammography'
   AND vs.system = o.code_system AND vs.code = o.code
  WHERE o.status IN ('final', 'amended', 'corrected')
    AND julianday(o.effective) BETWEEN julianday(:period_start) AND julianday(:period_end)
),
-- define "Numerator": exists "Mammograms During Period"
numerator AS (
  SELECT p.id AS patient_id,
         EXISTS (SELECT 1 FROM mammograms_during_period m WHERE m.patient_id = p.id) AS v
  FROM patient p
)
-- populations, patient-based proportion scoring: denominator ⊆ initial population,
-- numerator ⊆ denominator ("Denominator" is "Initial Population")
SELECT ip.patient_id AS patient_id,
       ip.v AS "initial-population",
       ip.v AS "denominator",
       (ip.v AND n.v) AS "numerator"
FROM initial_population ip
JOIN numerator n ON n.patient_id = ip.patient_id
ORDER BY ip.patient_id;
