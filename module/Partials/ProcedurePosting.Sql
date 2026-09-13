-- Parameters passed from your SaaS application layer
DECLARE @ProcedureGuid nvarchar(50), 
    @FacilityId nvarchar(50);

-- Initialize local parameter variables
DECLARE 
    @PatientId NVARCHAR(50),
    @PatientVisit NVARCHAR(50),
    @ServiceDate DATETIME, 
    @ContractGuid NVARCHAR(50), 
    @Manual VARCHAR(20), 
    @AdjustmentPct DECIMAL(5,2), 
    @ClaimGuid NVARCHAR(50), -- FIXED: Physically added the missing structural comma here
    @ShiftType INT;

-- 1a. COMPLIANCE REGISTRY: Official Colombian Legal Holidays (Projected 2024 - 2030)
WITH ColombianHolidays AS (
    SELECT CAST(HolidayDate AS DATE) AS HolidayDate FROM (VALUES
        ('2024-01-01'),('2024-01-08'),('2024-03-25'),('2024-03-28'),('2024-03-29'),('2024-05-01'),('2024-05-13'),('2024-06-03'),('2024-06-10'),('2024-07-01'),('2024-07-20'),('2024-08-07'),('2024-08-19'),('2024-10-14'),('2024-11-04'),('2024-11-11'),('2024-12-08'),('2024-12-25'),
        ('2025-01-01'),('2025-01-13'),('2025-03-24'),('2025-04-17'),('2025-04-18'),('2025-05-01'),('2025-06-02'),('2025-06-23'),('2025-06-30'),('2025-07-20'),('2025-08-07'),('2025-08-18'),('2025-10-13'),('2025-11-03'),('2025-11-16'),('2025-12-08'),('2025-12-25'),
        ('2026-01-01'),('2026-01-12'),('2026-03-23'),('2026-04-02'),('2026-04-03'),('2026-05-01'),('2026-05-18'),('2026-06-08'),('2026-06-15'),('2026-06-29'),('2026-07-20'),('2026-08-07'),('2026-08-17'),('2026-10-12'),('2026-11-02'),('2026-11-16'),('2026-12-08'),('2026-12-25'),
        ('2027-01-01'),('2027-01-11'),('2027-03-22'),('2027-03-25'),('2027-03-26'),('2027-05-01'),('2027-05-10'),('2027-05-31'),('2027-06-07'),('2027-07-05'),('2027-07-12'),('2027-07-20'),('2027-08-07'),('2027-08-16'),('2027-10-18'),('2027-11-01'),('2027-11-15'),('2027-12-08'),('2027-12-25'),
        ('2028-01-01'),('2028-01-10'),('2028-03-20'),('2028-04-13'),('2028-04-14'),('2028-05-01'),('2028-05-29'),('2028-06-19'),('2028-06-26'),('2028-07-10'),('2028-07-20'),('2028-08-07'),('2028-08-21'),('2028-10-16'),('2028-11-06'),('2028-11-13'),('2028-12-08'),('2028-12-25'),
        ('2029-01-01'),('2029-01-08'),('2029-03-19'),('2029-03-29'),('2029-03-30'),('2029-05-01'),('2029-06-04'),('2029-06-11'),('2029-07-02'),('2029-07-20'),('2029-08-07'),('2029-08-20'),('2029-10-15'),('2029-11-05'),('2029-11-12'),('2029-12-08'),('2029-12-25'),
        ('2030-01-01'),('2030-01-07'),('2030-03-25'),('2030-04-18'),('2030-04-19'),('2030-05-01'),('2030-06-03'),('2030-06-24'),('2030-07-01'),('2030-07-08'),('2030-07-20'),('2030-08-07'),('2030-08-19'),('2030-10-14'),('2030-11-04'),('2030-11-11'),('2030-12-08'),('2030-12-25')
    ) AS h(HolidayDate)
),
ProceduralTarget AS (
    SELECT 
        pp.PatientId,
        pp.PatientVisit,
        ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS TargetDate,
        pyx.ClaimGuid,
        pyx.ContractGuid,
        pyx.EntityCode,
        pyx.AdjustmentPct,
        CASE WHEN h.HolidayDate IS NOT NULL THEN 1 ELSE 0 END AS IsHoliday
    FROM ClinicalGeniusEhr.dbo.PatientProcedures pp WITH(NOLOCK)
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS DATE)
    OUTER APPLY (
        SELECT TOP 1 
            pyc.ClaimGuid, 
            ppy.ContractGuid, 
            isc.EntityCode, 
            isc.AdjustmentPct 
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) ON ppy.PatientPayerGuid = pyc.PayerGuid
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) ON isc.ContractGuid = pyc.ContractGuid
        WHERE pyc.PatientVisit = pp.PatientVisit 
          AND pyc.Status = 'Pending'
        ORDER BY ppy.Ordinal ASC
    ) pyx
    WHERE pp.ProcedureGuid = @ProcedureGuid AND pp.Deleted = 0
)
-- 1b. Assign extracted properties to local scalar execution variables
SELECT 
    @PatientId     = Target.PatientId,
    @PatientVisit  = Target.PatientVisit,
    @ServiceDate   = Target.TargetDate,
    @ContractGuid  = Target.ContractGuid,
    @Manual        = Target.EntityCode,
    @AdjustmentPct = Target.AdjustmentPct,
    @ClaimGuid     = Target.ClaimGuid, 
    @ShiftType     = CASE 
                        WHEN Target.IsHoliday = 1 THEN 4 
                        WHEN (DATEPART(dw, Target.TargetDate) + @@DATEFIRST + 5) % 7 + 1 IN (6, 7) THEN 4 
                        WHEN DATEPART(hour, Target.TargetDate) < 7 THEN 3 
                        WHEN DATEPART(hour, Target.TargetDate) > 18 THEN 3 
                        ELSE 2 
                     END
FROM ProceduralTarget Target;

-- 1c. Dynamic Yearly Index Configurations
DECLARE @YearOfService INT = YEAR(@ServiceDate);
DECLARE @Smdlv DECIMAL(18,2) = CASE @YearOfService WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 WHEN 2028 THEN 57540.00 WHEN 2029 THEN 57540.00 WHEN 2030 THEN 57540.00 ELSE 0 END;
DECLARE @Uvb DECIMAL(18,2) = CASE @YearOfService WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 WHEN 2028 THEN 12110.00 WHEN 2029 THEN 12110.00 WHEN 2030 THEN 12110.00 ELSE 0 END;

-- 2. Build pipeline calculation matrix
WITH StandaloneException AS (
    SELECT 
        pp.ProcedureGuid,
        pp.ProcedureCode,
        pp.ProcedureDescription,
        pp.LaterialityCode,
        ce.PriceModifier AS ExceptionPriceModifier, 
        ce.ExceptionGuid,
        -- Evaluate exception precision matching dynamically to establish priority
        ROW_NUMBER() OVER (
            PARTITION BY pp.ProcedureGuid
            ORDER BY CASE 
                WHEN ce.ShiftType = @ShiftType AND ce.ServiceGroup = pp.ServiceGroup AND ce.SurgeryGroups = pp.ProcedureCode THEN 1
                WHEN ce.ShiftType = 1          AND ce.ServiceGroup = pp.ServiceGroup AND ce.SurgeryGroups = pp.ProcedureCode THEN 2
                WHEN ce.ShiftType = 1          AND ce.ServiceGroup = '00'            AND ce.SurgeryGroups = pp.ProcedureCode THEN 3
                WHEN ce.ShiftType = 1          AND ce.ServiceGroup = '00'            AND ce.SurgeryGroups IS NULL           THEN 4
                ELSE 5
            END ASC,
            ABS(ce.PriceModifier) DESC, 
            ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM ClinicalGeniusEhr.dbo.PatientProcedures pp WITH(NOLOCK)
    -- Kept for structural validation requirements
    INNER JOIN ClinicalGeniusSupplyChain.dbo.PatientProcedureAdministration ppa WITH(NOLOCK) 
        ON ppa.RVSCode = pp.ProcedureCode 
        AND ppa.Active = 1
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = @ContractGuid 
        AND ce.Active = 1 
        AND @ServiceDate >= ce.StartDate 
        AND @ServiceDate <= ISNULL(ce.EndDate, '9999-12-31') 
        -- Fixed: Enabled off-hours shift exceptions to bypass the hardcoded shift block
        AND (ce.ShiftType = 1 OR ce.ShiftType = @ShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = pp.ServiceGroup) 
        AND (ce.SurgeryGroups IS NULL OR ce.SurgeryGroups = pp.ProcedureCode) 
    WHERE pp.ProcedureGuid = @ProcedureGuid
),
-- Section 3
-- 3. Map unified catalog base units and capture monetary indices
BaseUnitsLookup AS (
    SELECT 
        se.ProcedureGuid,
        se.ProcedureCode,
        se.ProcedureDescription,
        se.LaterialityCode,
        se.ExceptionGuid,
        -- STEP A: Safely compute combined markup fraction using the matched tier modifier
        CAST(1 + (@AdjustmentPct / 100.00) + (ISNULL(se.ExceptionPriceModifier, 0.00) / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        -- STEP B: Lookup raw units from corresponding tariff master index
        CAST(CASE 
            WHEN @Manual = 'SOAT' THEN ISNULL(soat.BaseUnits, 0.00)
            WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN ISNULL(iss.UvrPoints, 0.00)
            ELSE 1.00 
        END AS DECIMAL(18,2)) AS RawCatalogUnits,
        -- STEP C: Identify legal unit basis required for clear audit trails
        CASE 
            WHEN @Manual = 'SOAT' AND @ServiceDate < '2024-01-01' THEN 'SMDLV'
            WHEN @Manual = 'SOAT' AND @ServiceDate >= '2024-01-01' THEN 'UVB'
            WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN 'UVT' 
            ELSE 'COP' 
        END AS ValueBasis,
        -- STEP D: Capture exact conversion rate from Section 1c parameters
        CASE 
            WHEN @Manual = 'SOAT' AND @ServiceDate < '2024-01-01' THEN @Smdlv
            WHEN @Manual = 'SOAT' AND @ServiceDate >= '2024-01-01' THEN @Uvb
            WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN @Smdlv 
            ELSE 1.00 
        END AS UnitMonetaryValue
    FROM StandaloneException se
    -- Join to master SOAT tariff table via procedure code identifier mappings
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.MasterSoatGroups soat WITH(NOLOCK) 
        ON @Manual = 'SOAT' 
        AND soat.ProcedureCode = se.ProcedureCode 
        AND soat.SubtypeCode = 1 -- Defaults to standard single clinical care base line mapping
    -- Join to master ISS relative point master table
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.MasterIssUvr iss WITH(NOLOCK) 
        ON @Manual IN ('ISS_2001', 'ISS_2004') 
        AND iss.RVSCode = se.ProcedureCode
    WHERE se.ExceptionPriorityRank = 1 -- Filters out duplicate exception matches completely
)

-- 10. Post to PatientTransactions ledger
-- Final insertion of single outpatient procedure records into the persistent transactional ledger
INSERT INTO ClinicalGeniusSupplyChain.PatientTransactions (
    Facility, PatientId, PatientVisit, TransactionType, ClaimGuid, SurgeryGuid, ContractGuid, 
    ContractExceptionGuid, Ambity, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
    SameApproach, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
    DateTimeEntered, RevenueCode, Quantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
    USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
    PerItemChargeAmount, [Status]
)
SELECT 
    @FacilityId, 
    @PatientId, 
    @PatientVisit, 
    'Procedure',                        -- TransactionType explicitly categorized as a standalone procedure
    @ClaimGuid, 
    NULL,                               -- SurgeryGuid is NULL for non-surgical outpatient procedures
    @ContractGuid, 
    f.ExceptionGuid, 
    '04',                               -- Ambity set explicitly to outpatient care code
    f.UnitMonetaryValue, 
    f.ProcedureDescription, 
    NULL,                               -- SurgicalGroup is omitted for standalone billing lines
    NULL,                               -- SurgicalApproach is omitted for non-surgical procedures
    0,                                  -- SameApproach defaults to 0 for standalone entries
    1,                                  -- ShiftTypeApplied defaults to standard base shifts for clinical records
    0.00,                               -- SurchargeAmount
    f.ProcedureCode, 
    NULL,                               -- CUMCode
    @ServiceDate, 
    GETDATE(),                          -- DateTimeEntered tracking timestamp
    @Manual,                            -- RevenueCode tracking tariff manual code
    1,                                  -- Quantity
    1,                                  -- ItemCost (Financial liquidation rank defaults to 1)
    f.LaterialityCode, 
    f.RawCatalogUnits, 
    f.BaseCalculatedValue, 
    1.00,                               -- USDBasePrice (Degradation multiplier defaults to 1.00 face value)
    1.00,                               -- USDPerItemChargeAmount (Shift multiplier defaults to 1.00 face value)
    f.ValueBasis,
    CAST((f.RawCatalogUnits * f.BaseCalculatedValue * f.UnitMonetaryValue) AS DECIMAL(18,2)), -- NetAmount
    0.00,                               -- TaxAmount
    0.00,                               -- DiscountAmount
    CAST((f.RawCatalogUnits * f.BaseCalculatedValue * f.UnitMonetaryValue) AS DECIMAL(18,2)), -- PerItemChargeAmount
    'Active'                            -- [Status]
FROM BaseUnitsLookup f;

-- Return confirmation metrics to the SaaS application layer
SELECT @@ROWCOUNT AS RecordsPosted;
