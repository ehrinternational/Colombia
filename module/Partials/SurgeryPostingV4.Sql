-- ========================================================================================
-- SAAS BILLING LAYER: COLOMBIAN SURGICAL LIQUIDATION ENGINE (SOAT / ISS COMPLIANT)
-- ========================================================================================
-- Section 1
-- Parameters passed from your SaaS application layer
DECLARE @SurgeryGuid nvarchar(50), @FacilityId nvarchar(50), @PatientId nvarchar(50), 
    @PatientVisit nvarchar(50);

-- 1a. Initialize local parameter variables
DECLARE @ServiceDate DATETIME, @ContractGuid NVARCHAR(50), @Laterality INT, @SurgeryApproach INT,      
        @ShiftType INT, @AdjustmentPct DECIMAL(5,2), @Manual VARCHAR(20), @FeesIncluded BIT,        
        @RoomIncluded BIT, @AnesthesiaIncluded BIT, @AssistantIncluded BIT, @ClaimGuid NVARCHAR(50);   

-- 1b. COMPLIANCE REGISTRY: Official Colombian Legal Holidays (Projected 2024 - 2030)
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
SurgeryContext AS (
    SELECT SCS.DateTimePerformed, 
            CAST(PPY.ContractGuid AS NVARCHAR(50)) AS ContractGuid, 
            PYX.ClaimGuid,
            SCS.Laterality, 
            SCS.SurgeryApproach, 
            ISC.EntityCode, 
            ISC.AdjustmentPct,
            CAST(ISNULL(SCS.FeesIncluded, 0) AS BIT) AS FeesIncluded, 
            CAST(ISNULL(SCS.RoomIncluded, 0) AS BIT) AS RoomIncluded,
            CAST(ISNULL(SCS.AnesthesiaIncluded, 0) AS BIT) AS AnesthesiaIncluded, 
            CAST(ISNULL(SCS.AssistantIncluded, 0) AS BIT) AS AssistantIncluded,
            CASE WHEN h.HolidayDate IS NOT NULL THEN 1 ELSE 0 END AS IsHoliday
    FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries SCS WITH(NOLOCK) 
    LEFT JOIN ClinicalGeniusEhr.dbo.PatientPayers PPY WITH(NOLOCK) ON PPY.PatientPayerGuid = SCS.PatientPayerGuid
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts ISC WITH(NOLOCK) ON CAST(ISC.ContractGuid AS NVARCHAR(50)) = CAST(PPY.ContractGuid AS NVARCHAR(50))
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(SCS.DateTimePerformed AS DATE)
    OUTER APPLY
        (SELECT Top 1 PYC.ClaimGuid 
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims PYC WITH(NOLOCK)
        WHERE PYC.PatientVisit = @PatientVisit
        AND PYC.PayerGuid = SCS.PatientPayerGuid
        AND PYC.Status = 'Pending') PYX
    WHERE SCS.SurgeryGuid = @SurgeryGuid
)
SELECT @ServiceDate = DateTimePerformed, @ContractGuid = ContractGuid, @Laterality = Laterality, @SurgeryApproach = SurgeryApproach, 
       @Manual = EntityCode, 
       @AdjustmentPct = AdjustmentPct, 
       @FeesIncluded = FeesIncluded, 
       @RoomIncluded = RoomIncluded, 
       @AnesthesiaIncluded = AnesthesiaIncluded,
       @AssistantIncluded = AssistantIncluded,
       @ClaimGuid = ClaimGuid,
       @ShiftType = CASE WHEN IsHoliday = 1 THEN 4 
       WHEN (DATEPART(dw, DateTimePerformed) + @@DATEFIRST + 5) % 7 + 1 IN (6, 7) THEN 4 
       WHEN DATEPART(hour, DateTimePerformed) < 7 THEN 3 
       WHEN DATEPART(hour, DateTimePerformed) > 18 THEN 3 
       ELSE 2 END
FROM SurgeryContext;

-- 1c. Dynamic Yearly Index Configurations
DECLARE @YearOfService INT = YEAR(@ServiceDate);
DECLARE @Smdlv DECIMAL(18,2) = CASE @YearOfService WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 WHEN 2028 THEN 57540.00 WHEN 2029 THEN 57540.00 WHEN 2030 THEN 57540.00 ELSE 0 END;
DECLARE @Uvb DECIMAL(18,2) = CASE @YearOfService WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 WHEN 2028 THEN 12110.00 WHEN 2029 THEN 12110.00 WHEN 2030 THEN 12110.00 ELSE 0 END;

-- ========================== CORE PIPELINE PIPING ==========================
-- Section 2
WITH ProcedureList AS (
    SELECT s.SurgeryGuid, @ContractGuid AS ContractGuid, @Laterality AS Laterality, v.RowNumber, v.ProcedureGuid, v.SameApproach
    FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK) 
    CROSS APPLY (VALUES (CAST(1 AS TINYINT), s.PrimaryProcedure, CAST(0 AS BIT)), (2, s.SecondaryProcedure, CAST(ISNULL(s.Incision2, 0) AS BIT)), (3, s.Procedure3, CAST(ISNULL(s.Incision3, 0) AS BIT)), (4, s.Procedure4, CAST(ISNULL(s.Incision4, 0) AS BIT)), (5, s.Procedure5, CAST(ISNULL(s.Incision5, 0) AS BIT)), (6, s.Procedure6, CAST(ISNULL(s.Incision6, 0) AS BIT)), (7, s.Procedure7, CAST(ISNULL(s.Incision7, 0) AS BIT))) v(RowNumber, ProcedureGuid, SameApproach)
    WHERE s.SurgeryGuid = @SurgeryGuid AND v.ProcedureGuid IS NOT NULL 
),
-- Section 3
ProceduresWithCodes AS (
    SELECT pl.*, pai.RVSCode, pai.SurgicalGroup, pai.HCPCSCode 
    FROM ProcedureList pl
    INNER JOIN ClinicalGeniusEhr.dbo.ProcedureAdministrationItems pai WITH(NOLOCK) 
    ON pl.ProcedureGuid = pai.ProcedureGuid 
),
-- Section 4
-- 4a. Match and score all category contract exceptions using the multi-field matrix
AllMatchingExceptions AS (
    SELECT 
        p.SurgeryGuid,
        p.ContractGuid,
        p.Laterality,
        p.RowNumber,
        p.ProcedureGuid,
        p.SameApproach,
        p.RVSCode, 
        p.SurgicalGroup,
        p.HCPCSCode,
        ce.PriceModifier AS ExceptionPriceModifier, 
        ce.ExceptionGuid, -- Added missing passthrough tracking field
        -- Evaluate exception precision matching dynamically to establish priority
        ROW_NUMBER() OVER (
            PARTITION BY p.SurgeryGuid, p.ProcedureGuid, p.RowNumber
            ORDER BY CASE 
                WHEN ce.ShiftType = @ShiftType AND ce.ServiceGroup = '04' AND ce.SurgeryGroups = p.HCPCSCode THEN 1
                WHEN ce.ShiftType = 1          AND ce.ServiceGroup = '04' AND ce.SurgeryGroups = p.HCPCSCode THEN 2
                WHEN ce.ShiftType = 1          AND ce.ServiceGroup = '00' AND ce.SurgeryGroups = p.HCPCSCode THEN 3
                WHEN ce.ShiftType = 1          AND ce.ServiceGroup = '00' AND ce.SurgeryGroups IS NULL       THEN 4
                ELSE 5
            END ASC,
            -- CRUCIAL TIE-BREAKER: Resolves strict 1-to-1 matching if modifiers or dates tie
            ABS(ce.PriceModifier) DESC, 
            ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM ProceduresWithCodes p
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = p.ContractGuid 
        AND ce.Active = 1 
        AND @ServiceDate >= ce.StartDate 
        AND @ServiceDate <= ISNULL(ce.EndDate, '9999-12-31') 
        AND (ce.ShiftType = 1 OR ce.ShiftType = @ShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '04') 
        AND (ce.SurgeryGroups IS NULL OR ce.SurgeryGroups = p.HCPCSCode) 
),
-- 4b. Filter to keep ONLY the single highest scoring category exception match
ProceduresWithAppliedExceptions AS (
    SELECT 
        SurgeryGuid, 
        ContractGuid, 
        @ServiceDate AS ServiceDate, 
        @ShiftType AS ShiftType,     
        RowNumber, 
        ProcedureGuid, 
        SameApproach, 
        Laterality, 
        RVSCode, 
        SurgicalGroup, 
        HCPCSCode,
        ExceptionGuid, -- Passed safely downstream to bind with the final transaction table
        ISNULL(ExceptionPriceModifier, 0.00) AS PriceModifier
    FROM AllMatchingExceptions
    WHERE ExceptionPriorityRank = 1 
),
-- Section 5
-- Split procedures into the 5 standard billing pillars and apply inclusion/exclusion logic
FinalLineItemPricing AS (
    SELECT 
        pe.SurgeryGuid, 
        pe.ContractGuid, 
        pe.ServiceDate, 
        pe.ShiftType, 
        pe.RowNumber, 
        pe.ProcedureGuid, 
        pe.SameApproach, 
        pe.Laterality, 
        pe.RVSCode, 
        pe.SurgicalGroup, 
        pe.HCPCSCode,
        pe.ExceptionGuid, -- Preserved passthrough integrity
        pe.PriceModifier,
        v.SubtypeCode, 
        v.SubtypeName,
        -- STEP A: Safely determine if this specific pillar is bundled using the explicit parameters from Section 1
        CAST(
            CASE 
                WHEN v.SubtypeCode = 1 AND @FeesIncluded = 1       THEN 1 
                WHEN v.SubtypeCode = 2 AND @AnesthesiaIncluded = 1 THEN 1 
                WHEN v.SubtypeCode = 3 AND @AssistantIncluded = 1  THEN 1 
                WHEN v.SubtypeCode = 4 AND @RoomIncluded = 1        THEN 1 
                ELSE 0 
            END AS BIT
        ) AS IsBundledInPackage,
        -- STEP B: Compute unified percentage base scaling value
        CAST(1 + (@AdjustmentPct / 100.00) + (pe.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue
    FROM ProceduresWithAppliedExceptions pe
    CROSS APPLY (VALUES 
          (1, 'Cirujano')
        , (2, 'Anestesiologo')
        , (3, 'Ayudante')
        , (4, 'Sala')
        , (5, 'Materiales')
    ) v(SubtypeCode, SubtypeName)
),
--Section 6
CatalogBaseUnits AS (
    SELECT f.*, CAST(CASE WHEN f.IsBundledInPackage = 1 THEN 0.00 
    WHEN @Manual = 'SOAT' THEN ISNULL(soat.BaseUnits, 0.00) 
    WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN ISNULL(iss.UvrPoints, 0.00) 
    ELSE 0.00 END AS DECIMAL(18,2)) AS RawCatalogUnits
    FROM FinalLineItemPricing f
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.MasterSoatGroups soat WITH(NOLOCK) ON @Manual = 'SOAT' AND soat.SurgicalGroup = f.SurgicalGroup AND soat.SubtypeCode = f.SubtypeCode
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.MasterIssUvr iss WITH(NOLOCK) ON @Manual IN ('ISS_2001', 'ISS_2004') AND iss.RVSCode = f.RVSCode AND iss.SubtypeCode = f.SubtypeCode
),
-- Section 7
-- Rank procedures dynamically by complexity (highest units first per pillar)
ComplexityRanking AS (
    SELECT 
        SurgeryGuid, 
        ContractGuid, 
        Laterality, 
        RowNumber, 
        ProcedureGuid, 
        SameApproach, 
        RVSCode, 
        SurgicalGroup, 
        ServiceDate, 
        ShiftType, 
        SubtypeCode, 
        SubtypeName, 
        IsBundledInPackage, 
        BaseCalculatedValue, 
        RawCatalogUnits,
        ExceptionGuid, -- Fixed: Reintroduced missing passthrough mapping for Section 10 persistence
        ROW_NUMBER() OVER (
            PARTITION BY SurgeryGuid, SubtypeCode 
            ORDER BY RawCatalogUnits DESC, RowNumber ASC
        ) AS FinancialRank
    FROM CatalogBaseUnits
),
-- Section 8
SurgicalDegradationRules AS (
    SELECT r.*, CAST(CASE 
    WHEN r.FinancialRank = 1 THEN CASE WHEN r.Laterality = 3 AND r.SubtypeCode IN (1, 2, 3) THEN 1.75 
    WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 
    ELSE 1.00 END 
    WHEN r.FinancialRank > 1 AND r.SameApproach = 1 THEN 
    CASE WHEN r.SubtypeCode IN (1, 2, 3) THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END) 
    WHEN r.SubtypeCode = 4 THEN 0.00 WHEN r.SubtypeCode = 5 THEN 0.00 ELSE 0.50 END 
    WHEN r.FinancialRank > 1 AND r.SameApproach = 0 THEN CASE WHEN @Manual = 'SOAT' THEN 1.00 
    ELSE 0.75 END * CASE WHEN r.Laterality = 3 AND r.SubtypeCode IN (1, 2, 3) THEN 1.75 
    WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 ELSE 1.00 END 
    ELSE 1.00 END AS DECIMAL(10,4)) AS DegradationMultiplier
    FROM ComplexityRanking r
),
-- Section 9
FinalShiftAdjustments AS (
    SELECT d.*, CAST(CASE WHEN d.ShiftType IN (3, 4) AND d.SubtypeCode IN (1, 2, 3) THEN 1.25 ELSE 1.00 END AS DECIMAL(10,4)) AS ShiftMultiplier,
        CASE WHEN @Manual = 'SOAT' AND @ServiceDate < '2024-01-01' THEN 'SMDLV' WHEN @Manual = 'SOAT' AND @ServiceDate >= '2024-01-01' THEN 'UVB' WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN 'UVT' ELSE 'COP' END AS ValueBasis,
        CASE WHEN @Manual = 'SOAT' AND @ServiceDate < '2024-01-01' THEN @Smdlv WHEN @Manual = 'SOAT' AND @ServiceDate >= '2024-01-01' THEN @Uvb WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN @Smdlv ELSE 1.00 END AS UnitMonetaryValue
    FROM SurgicalDegradationRules d
)
-- ========================== PERSISTENT STORAGE INSERT ==========================
-- Section 10
-- Final insertion of category-calculated surgical line items into persistent ledger
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
    'Surgery',                          -- TransactionType
    @ClaimGuid,                         -- ClaimGuid mapped dynamically from Section 1's OUTER APPLY pass
    f.SurgeryGuid, 
    f.ContractGuid, 
    f.ExceptionGuid,                    -- ContractExceptionGuid tracking category lineage
    '04',                               -- Ambity set explicitly to outpatient surgical care code
    f.UnitMonetaryValue,                -- BaseUnitValue
    f.SubtypeName,                      -- SurgicalComponent
    f.SurgicalGroup, 
    @SurgeryApproach,                   -- SurgicalApproach
    f.SameApproach, 
    f.ShiftType,                        -- ShiftTypeApplied
    0.00,                               -- SurchargeAmount
    f.RVSCode,                          -- CupsCode
    NULL,                               -- CUMCode
    f.ServiceDate,                      -- ExternalProcessedDateTime
    GETDATE(),                          -- DateTimeEntered
    @Manual,                            -- RevenueCode
    1,                                  -- Quantity
    f.FinancialRank,                    -- ItemCost (1-7 complexity rank)
    f.Laterality,                       -- ItemSnomedCode
    f.RawCatalogUnits,                  -- ItemAlternateCode
    f.BaseCalculatedValue,              -- LocalAmount
    f.DegradationMultiplier,            -- USDBasePrice
    f.ShiftMultiplier,                  -- USDPerItemChargeAmount
    f.ValueBasis,                       -- PaymentType
    -- Standard Unified Percentage Liquidation Mathematical formula
    CAST((f.RawCatalogUnits * f.BaseCalculatedValue * f.DegradationMultiplier * f.ShiftMultiplier * f.UnitMonetaryValue) AS DECIMAL(18,2)), -- NetAmount
    0.00,                               -- TaxAmount
    0.00,                               -- DiscountAmount
    CAST((f.RawCatalogUnits * f.BaseCalculatedValue * f.DegradationMultiplier * f.ShiftMultiplier * f.UnitMonetaryValue) AS DECIMAL(18,2)), -- PerItemChargeAmount
    'Active'                            -- [Status]
FROM FinalShiftAdjustments f;

-- Optional verification confirmation for your SaaS backend API
SELECT @@ROWCOUNT AS RecordsPosted;
