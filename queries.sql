-- ============================================
-- NHS England A&E Capacity Strain Analysis
-- Data: NHS England A&E statistics, Jan-Aug 2026
-- ============================================

-- STEP 1: Combine 8 monthly CSV imports into one table
CREATE TABLE ae_combined AS
SELECT "Period", "Org Code", "Parent Org", "Org name",
       "A&E attendances Type 1", "A&E attendances Type 2", "A&E attendances Other A&E Department",
       "A&E attendances Booked Appointments Type 1", "A&E attendances Booked Appointments Type 2", "A&E attendances Booked Appointments Other Department",
       "Attendances over 4hrs Type 1", "Attendances over 4hrs Type 2", "Attendances over 4hrs Other Department",
       "Attendances over 4hrs Booked Appointments Type 1", "Attendances over 4hrs Booked Appointments Type 2", "Attendances over 4hrs Booked Appointments Other Department",
       "Patients who have waited 4-12 hs from DTA to admission", "Patients who have waited 12+ hrs from DTA to admission",
       "Emergency admissions via A&E - Type 1", "Emergency admissions via A&E - Type 2", "Emergency admissions via A&E - Other A&E department",
       "Other emergency admissions"
FROM ae_jan2026
UNION ALL SELECT * FROM ae_feb2026
UNION ALL SELECT * FROM ae_mar2026
UNION ALL SELECT * FROM ae_apr2026
UNION ALL SELECT * FROM ae_may2026
UNION ALL SELECT * FROM ae_jun2026
UNION ALL SELECT * FROM ae_jul2026
UNION ALL SELECT * FROM ae_aug2026;

-- STEP 2: Remove England-wide summary/total rows (catches both "Total" and "TOTAL" spellings)
CREATE TABLE ae_clean AS
SELECT *
FROM ae_combined
WHERE UPPER("Org Code") <> 'TOTAL'
  AND UPPER("Period") <> 'TOTAL';

-- STEP 3: Add a proper chronological sort order (Period is text and won't sort correctly on its own)
ALTER TABLE ae_clean ADD COLUMN month_order INTEGER;
UPDATE ae_clean SET month_order = 1 WHERE "Period" = 'MSitAE-JANUARY-2026';
UPDATE ae_clean SET month_order = 2 WHERE "Period" = 'MSitAE-FEBRUARY-2026';
UPDATE ae_clean SET month_order = 3 WHERE "Period" = 'MSitAE-MARCH-2026';
UPDATE ae_clean SET month_order = 4 WHERE "Period" = 'MSitAE-APRIL-2026';
UPDATE ae_clean SET month_order = 5 WHERE "Period" = 'MSitAE-MAY-2026';
UPDATE ae_clean SET month_order = 6 WHERE "Period" = 'MSitAE-JUNE-2026';
UPDATE ae_clean SET month_order = 7 WHERE "Period" = 'MSitAE-JULY-2026';
UPDATE ae_clean SET month_order = 8 WHERE "Period" = 'MSitAE-AUGUST-2026';

-- STEP 4: Calculate total attendances and total 4-hour breaches per trust per month
CREATE TABLE ae_metrics AS
SELECT
    "Period", month_order, "Org Code", "Org name", "Parent Org",
    ("A&E attendances Type 1" + "A&E attendances Type 2" + "A&E attendances Other A&E Department") AS total_attendances,
    ("Attendances over 4hrs Type 1" + "Attendances over 4hrs Type 2" + "Attendances over 4hrs Other Department") AS total_over_4hrs,
    "Patients who have waited 4-12 hs from DTA to admission" AS wait_4_12hrs,
    "Patients who have waited 12+ hrs from DTA to admission" AS wait_12hrs_plus,
    ("Emergency admissions via A&E - Type 1" + "Emergency admissions via A&E - Type 2" + "Emergency admissions via A&E - Other A&E department") AS total_emergency_admissions
FROM ae_clean;

-- STEP 5: Calculate % of patients seen within 4 hours, per trust per month
-- Filters out very small units where percentages are statistically unstable
CREATE TABLE ae_pct AS
SELECT "Org name", "Org Code", month_order,
       total_attendances, total_over_4hrs,
       ROUND((total_attendances - total_over_4hrs) * 100.0 / total_attendances, 1) AS pct_within_4hrs
FROM ae_metrics
WHERE total_attendances > 1000;

-- STEP 6: Compare January vs. August performance per trust (correctly directioned:
-- positive change = improved, negative = declined)
CREATE TABLE ae_trend AS
SELECT "Org Code", "Org name", jan_pct, aug_pct,
       ROUND(aug_pct - jan_pct, 1) AS change_jan_to_aug,
       CASE WHEN aug_pct > jan_pct THEN 'Improved'
            WHEN aug_pct < jan_pct THEN 'Declined'
            ELSE 'No change' END AS trend
FROM (
    SELECT "Org Code",
           MAX("Org name") AS "Org name",
           MAX(CASE WHEN month_order = 1 THEN pct_within_4hrs END) AS jan_pct,
           MAX(CASE WHEN month_order = 8 THEN pct_within_4hrs END) AS aug_pct
    FROM ae_pct
    GROUP BY "Org Code"
)
WHERE jan_pct IS NOT NULL AND aug_pct IS NOT NULL;

-- STEP 7: Calculate demand volatility per trust (relative ratio and absolute swing)
CREATE TABLE ae_volatility AS
SELECT "Org name",
       ROUND(max_attendances * 1.0 / avg_attendances, 2) AS volatility_ratio,
       max_attendances, avg_attendances, min_attendances,
       (max_attendances - min_attendances) AS absolute_swing
FROM (
    SELECT "Org name",
           MAX(total_attendances) AS max_attendances,
           AVG(total_attendances) AS avg_attendances,
           MIN(total_attendances) AS min_attendances
    FROM ae_metrics
    GROUP BY "Org name"
    HAVING AVG(total_attendances) > 1000
);

-- STEP 8: Combine both signals — trusts with BOTH declining performance
-- AND demand volatility, ranked by how large their swing was
CREATE TABLE ae_strain_signal AS
SELECT a."Org name", a.change_jan_to_aug, a.trend, v.volatility_ratio, v.absolute_swing
FROM ae_trend a
JOIN ae_volatility v ON a."Org name" = v."Org name"
WHERE a.trend = 'Declined'
ORDER BY v.absolute_swing DESC;
