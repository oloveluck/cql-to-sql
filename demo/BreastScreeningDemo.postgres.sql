-- BreastScreeningDemo.cql as SQL for PostgreSQL / Aidbox: the same CTEs as
-- BreastScreeningDemo.sql (SQLite), over the ViewDefinitions materialized in Aidbox's sof schema
-- (POST /fhir/ViewDefinition/$materialize with views/patient.json and views/observation.json).
--
-- Differences from the SQLite version: the measurement period is a params CTE (Aidbox's console
-- and $sql take no :named parameters), age is Postgres's age(), the value set is inline VALUES
-- (no valueset_code table in Aidbox), and columns are cast in case the views typed them as text.

WITH
params AS (
  SELECT TIMESTAMPTZ '2025-01-01T00:00:00.000Z' AS period_start,
         TIMESTAMPTZ '2025-12-31T23:59:59.999Z' AS period_end
),
-- valueset "Mammography": 'http://example.org/fhir/ValueSet/demo-mammography'
mammography (system, code) AS (
  VALUES ('http://loinc.org', '24606-6'),
         ('http://snomed.info/sct', '71651007')
),
-- define "Age at End of Period": AgeInYearsAt(date from end of "Measurement Period")
age_at_end_of_period AS (
  SELECT p.id AS patient_id,
         date_part('year', age((params.period_end AT TIME ZONE 'UTC')::date, p.birth_date::date))::int AS age
  FROM sof.patient p CROSS JOIN params
),
-- define "Initial Population": Patient.gender = 'female' and "Age at End of Period" in Interval[42, 74]
initial_population AS (
  SELECT p.id AS patient_id,
         COALESCE(p.gender = 'female' AND a.age BETWEEN 42 AND 74, false) AS v
  FROM sof.patient p JOIN age_at_end_of_period a ON a.patient_id = p.id
),
-- define "Mammograms During Period": [Observation: "Mammography"] O
--   where O.status in { 'final', 'amended', 'corrected' } and (O.effective as dateTime) during "Measurement Period"
mammograms_during_period AS (
  SELECT DISTINCT replace(o.patient_id, 'Patient/', '') AS patient_id, o.id
  FROM sof.observation o
  JOIN mammography vs ON vs.system = o.code_system AND vs.code = o.code
  CROSS JOIN params
  WHERE o.status IN ('final', 'amended', 'corrected')
    AND o.effective::timestamptz BETWEEN params.period_start AND params.period_end
),
-- define "Numerator": exists "Mammograms During Period"
numerator AS (
  SELECT p.id AS patient_id,
         EXISTS (SELECT 1 FROM mammograms_during_period m WHERE m.patient_id = p.id) AS v
  FROM sof.patient p
)
-- populations, patient-based proportion scoring: denominator ⊆ initial population,
-- numerator ⊆ denominator ("Denominator" is "Initial Population")
SELECT ip.patient_id AS patient_id,
       ip.v::int AS "initial-population",
       ip.v::int AS "denominator",
       (ip.v AND n.v)::int AS "numerator"
FROM initial_population ip
JOIN numerator n ON n.patient_id = ip.patient_id
ORDER BY ip.patient_id;
