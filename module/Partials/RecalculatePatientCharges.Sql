-- Section 1: Visit-Wide Contract Context Extraction
-- Parameters passed from your SaaS application layer
DECLARE @PatientVisit NVARCHAR(50), 
        @FacilityId NVARCHAR(50), 
        @PatientId NVARCHAR(50);

-- Initialize local parameters for unified contract context
DECLARE @ContractGuid NVARCHAR(50) = NULL, 
        @Manual VARCHAR(20) = 'SOAT',        -- Defaults to SOAT for Self-Pay fallback
        @AdjustmentPct DECIMAL(5,2) = 0.00,  -- Defaults to 0% margin for Self-Pay fallback
        @ClaimGuid NVARCHAR(50) = NULL,
        @FeesIncluded BIT = 0,               -- Added to capture bundle context from contract
        @RoomIncluded BIT = 0,               
        @AnesthesiaIncluded BIT = 0,         
        @AssistantIncluded BIT = 0;          

-- 1a. Extract active, pending primary contract variables and inclusion rules for the visit
SELECT TOP 1 
    @ClaimGuid          = pyc.ClaimGuid,
    @ContractGuid       = ppy.ContractGuid,
    @Manual             = isc.EntityCode,
    @AdjustmentPct      = isc.AdjustmentPct,
    @FeesIncluded       = CAST(ISNULL(isc.FeesIncluded, 0) AS BIT),       -- Sourced correctly from Contracts
    @RoomIncluded       = CAST(ISNULL(isc.RoomIncluded, 0) AS BIT),       -- Sourced correctly from Contracts
    @AnesthesiaIncluded = CAST(ISNULL(isc.AnesthesiaIncluded, 0) AS BIT), -- Sourced correctly from Contracts
    @AssistantIncluded  = CAST(ISNULL(isc.AssistantIncluded, 0) AS BIT)   -- Sourced correctly from Contracts
FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
    ON ppy.PatientPayerGuid = pyc.PayerGuid
INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
    ON isc.ContractGuid = ppy.ContractGuid
WHERE pyc.PatientVisit = @PatientVisit
  AND pyc.Status = 'Pending'
ORDER BY ppy.Ordinal ASC; 

-- 1b. Self-Pay Fallback Safeguard
-- If no active PayerClaim was found above, variables retain their default state.
-- Inclusion bits safely default to 0 (Unbundled / fully itemized billing lines).

-- Section 2: Targeted Pre-Invoice Staging Clearance
-- Purge all flexible insurance/payer transactions for the encounter visit to prepare for clean re-liquidation.
-- This strictly preserves any patient-responsibility lines (SelfPay = 1) in place.

DELETE FROM ClinicalGeniusSupplyChain.PatientTransactions
WHERE PatientVisit = @PatientVisit
  AND TransactionType IN ('Surgery', 'Procedure')
  -- CRUCIAL SAFETY CATCH: Prevents the engine from accidentally deleting the patient's private self-pay ledger entries
  AND ISNULL(SelfPay, 0) <> 1;

-- Capture rowcount metrics for internal SaaS validation tracing if needed
-- DECLARE @ClearedStagingRows INT = @@ROWCOUNT;

-- Section 3: Multi-Surgery Pipeline Matrix Execution
-- 3a. COMPLIANCE REGISTRY: Official Colombian Legal Holidays (Projected 2024 - 2030)
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
-- 3b. Embedded Inline Memory Array for SOAT Surgical Groups (1-13)
MasterSoatGroupsArray AS (
    SELECT SurgicalGroup, SubtypeCode, CAST(BaseUnits AS DECIMAL(18,2)) AS BaseUnits
    FROM (VALUES
          (1, 1, 1.14), (1, 2, 0.81), (1, 3, 0.35), (1, 4, 1.34), (1, 5, 0.82)
        , (2, 1, 1.63), (2, 2, 1.11), (2, 3, 0.49), (2, 4, 2.14), (2, 5, 1.30)
        , (3, 1, 2.37), (3, 2, 1.54), (3, 3, 0.69), (3, 4, 3.19), (3, 5, 1.83)
        , (4, 1, 3.01), (4, 2, 1.98), (4, 3, 0.84), (4, 4, 4.09), (4, 5, 2.45)
        , (5, 1, 3.73), (5, 2, 2.41), (5, 3, 1.01), (5, 4, 4.70), (5, 5, 3.42)
        , (6, 1, 4.67), (6, 2, 2.87), (6, 3, 1.25), (6, 4, 6.00), (6, 5, 4.07)
        , (7, 1, 5.66), (7, 2, 3.36), (7, 3, 1.51), (7, 4, 6.94), (7, 5, 4.70)
        , (8, 1, 6.75), (8, 2, 3.90), (8, 3, 1.80), (8, 4, 7.97), (8, 5, 5.37)
        -- FIXED: Corrected the subtype code value from 4 to 2 for the Group 9 Anesthesiologist record entry
        , (9, 1, 8.01), (9, 2, 4.41), (9, 3, 2.13), (9, 4, 9.07), (9, 5, 6.07)
        , (10, 1, 9.53), (10, 2, 5.03), (10, 3, 2.53), (10, 4, 11.23), (10, 5, 7.15)
        , (11, 1, 11.45), (11, 2, 5.75), (11, 3, 3.03), (11, 4, 13.68), (11, 5, 8.52)
        , (12, 1, 13.91), (12, 2, 6.64), (12, 3, 3.67), (12, 4, 16.92), (12, 5, 10.38)
        , (13, 1, 17.14), (13, 2, 7.76), (13, 3, 4.51), (13, 4, 21.04), (13, 5, 12.87)
    ) ArrayRows(SurgicalGroup, SubtypeCode, BaseUnits)
),
-- 3c. Embedded Inline Memory Array for ISS Facility Groups (20-23 Rooms & Materials)
MasterIssFacilityArray AS (
    SELECT IssSurgicalGroup, SubtypeCode, CAST(FacilityUvrPoints AS DECIMAL(18,2)) AS FacilityUvrPoints
    FROM (VALUES
          (20, 4, 55.00),  (20, 5, 40.00) 
        , (21, 4, 70.00),  (21, 5, 55.00) 
        , (22, 4, 105.00), (22, 5, 80.00) 
        , (23, 4, 145.00), (23, 5, 115.00)
    ) IssArrayRows(IssSurgicalGroup, SubtypeCode, FacilityUvrPoints)
),
-- 3d. Flatten all surgical records and compute time-of-care shift profiles row-by-row
ProcedureList AS (
    SELECT 
        s.SurgeryGuid,
        s.DateTimePerformed,
        s.Laterality,
        s.SurgeryApproach,
        YEAR(s.DateTimePerformed) AS YearOfService,
        v.RowNumber, 
        v.ProcedureGuid, 
        v.SameApproach,
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN (DATEPART(dw, s.DateTimePerformed) + @@DATEFIRST + 5) % 7 + 1 IN (6, 7) THEN 4
            WHEN DATEPART(hour, s.DateTimePerformed) < 7 THEN 3
            WHEN DATEPART(hour, s.DateTimePerformed) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType
    FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(s.DateTimePerformed AS DATE)
    -- Flattening the 7 surgical procedure slots from the base record rows
    CROSS APPLY (VALUES 
          (CAST(1 AS TINYINT), s.PrimaryProcedure,   CAST(0 AS BIT)) 
        , (2,                  s.SecondaryProcedure, CAST(ISNULL(s.Incision2, 0) AS BIT))
        , (3,                  s.Procedure3,         CAST(ISNULL(s.Incision3, 0) AS BIT))
        , (4,                  s.Procedure4,         CAST(ISNULL(s.Incision4, 0) AS BIT))
        , (5,                  s.Procedure5,         CAST(ISNULL(s.Incision5, 0) AS BIT))
        , (6,                  s.Procedure6,         CAST(ISNULL(s.Incision6, 0) AS BIT))
        , (7,                  s.Procedure7,         CAST(ISNULL(s.Incision7, 0) AS BIT))
    ) v(RowNumber, ProcedureGuid, SameApproach)
    WHERE s.PatientVisit = @PatientVisit 
      AND s.Status = 'Completed'
      AND v.ProcedureGuid IS NOT NULL
),
-- Section 4: Code Mapping & Category Exception Priority Scoring
-- 4a. Join clinical codes and metadata
ProceduresWithCodes AS (
    SELECT 
        pl.SurgeryGuid, pl.DateTimePerformed, pl.Laterality, pl.SurgeryApproach, pl.YearOfService,
        pl.RowNumber, pl.ProcedureGuid, pl.SameApproach, pl.RowShiftType,
        pai.RVSCode, pai.SurgicalGroup, pai.HCPCSCode 
    FROM ProcedureList pl
    INNER JOIN ClinicalGeniusEhr.dbo.ProcedureAdministrationItems pai WITH(NOLOCK) 
        ON pl.ProcedureGuid = pai.ProcedureGuid 
),

-- 4b. Score and rank contract exceptions dynamically row-by-row
AllMatchingExceptions AS (
    SELECT 
        p.*, 
        ce.PriceModifier AS ExceptionPriceModifier, 
        ce.ExceptionGuid,
        -- Evaluates category precision match rules across all concurrent operations
        ROW_NUMBER() OVER (
            PARTITION BY p.SurgeryGuid, p.ProcedureGuid, p.RowNumber
            ORDER BY CASE 
                WHEN ce.ShiftType = p.RowShiftType AND ce.ServiceGroup = '04' AND ce.SurgeryGroups = p.HCPCSCode THEN 1
                WHEN ce.ShiftType = 1              AND ce.ServiceGroup = '04' AND ce.SurgeryGroups = p.HCPCSCode THEN 2
                WHEN ce.ShiftType = 1              AND ce.ServiceGroup = '00' AND ce.SurgeryGroups = p.HCPCSCode THEN 3
                WHEN ce.ShiftType = 1              AND ce.ServiceGroup = '00' AND ce.SurgeryGroups IS NULL       THEN 4
                ELSE 5
            END ASC,
            ABS(ce.PriceModifier) DESC, 
            ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM ProceduresWithCodes p
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = @ContractGuid 
        AND ce.Active = 1 
        AND CAST(p.DateTimePerformed AS DATE) >= ce.StartDate 
        AND CAST(p.DateTimePerformed AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        AND (ce.ShiftType = 1 OR ce.ShiftType = p.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '04') 
        AND (ce.SurgeryGroups IS NULL OR ce.SurgeryGroups = p.HCPCSCode) 
),

-- 4c. Isolate only the absolute single highest scoring contract exception match
ProceduresWithAppliedExceptions AS (
    SELECT 
        SurgeryGuid, DateTimePerformed, Laterality, SurgeryApproach, YearOfService,
        RowNumber, ProcedureGuid, SameApproach, RowShiftType, RVSCode, SurgicalGroup, HCPCSCode,
        ExceptionGuid,
        ISNULL(ExceptionPriceModifier, 0.00) AS PriceModifier
    FROM AllMatchingExceptions
    WHERE ExceptionPriorityRank = 1 
),
-- Section 5: Batch Surgical Billing Pillar Splitting & Factor Evaluation
FinalLineItemPricing AS (
    SELECT 
        pe.SurgeryGuid,
        pe.DateTimePerformed,
        pe.Laterality,
        pe.SurgeryApproach,
        pe.YearOfService,
        pe.RowNumber,
        pe.ProcedureGuid,
        pe.SameApproach,
        pe.RowShiftType,
        pe.RVSCode,
        pe.SurgicalGroup,
        pe.HCPCSCode,
        pe.ExceptionGuid,
        pe.PriceModifier,
        v.SubtypeCode, 
        v.SubtypeName,
        
        -- STEP A: Safely determine if this specific pillar is bundled using Section 1 global contract tokens
        CAST(
            CASE 
                WHEN v.SubtypeCode = 1 AND @FeesIncluded = 1       THEN 1 -- Fixed to read global variable context
                WHEN v.SubtypeCode = 2 AND @AnesthesiaIncluded = 1 THEN 1 
                WHEN v.SubtypeCode = 3 AND @AssistantIncluded = 1  THEN 1 
                WHEN v.SubtypeCode = 4 AND @RoomIncluded = 1        THEN 1 
                ELSE 0 
            END AS BIT
        ) AS IsBundledInPackage,

        -- STEP B: Compute the unified percentage markup base factor
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
-- 6c. Consolidated Set-Based Unit Evaluator
CatalogBaseUnits AS (
    SELECT 
        f.*,
        CAST(
            CASE 
                -- Rule A: If this pillar is explicitly bundled in the contract package, its billable weight is zero
                WHEN f.IsBundledInPackage = 1 THEN 0.00
                
                -- Rule B: SOAT Manual Evaluation (Natively resolves weight from the embedded SOAT array using your direct field pass)
                WHEN @Manual = 'SOAT' THEN ISNULL(soat.BaseUnits, 0.00)
                
                -- Rule C: ISS Manual Evaluation for Professional Fees (Subtypes 1, 2, 3 map directly to your item row UVR values)
                WHEN @Manual IN ('ISS_2001', 'ISS_2004') AND f.SubtypeCode IN (1, 2, 3) THEN ISNULL(f.IssUvrPoints, 0.00)
                
                -- Rule D: ISS Manual Evaluation for Facility Fees (Subtypes 4, 5 resolve from the embedded ISS array using your direct group pass)
                WHEN @Manual IN ('ISS_2001', 'ISS_2004') AND f.SubtypeCode IN (4, 5) THEN ISNULL(iss.FacilityUvrPoints, 0.00)
                
                ELSE 0.00 
            END AS DECIMAL(18,2)
        ) AS RawCatalogUnits
    FROM FinalLineItemPricing f
    -- Join directly against the memory array matching your direct SoatSurgicalGroup field (1-13)
    LEFT JOIN MasterSoatGroupsArray soat 
        ON @Manual = 'SOAT' 
        AND soat.SurgicalGroup = f.SoatSurgicalGroup
        AND soat.SubtypeCode = f.SubtypeCode
    -- Join directly against the memory array matching your direct IssSurgicalGroup field (20-23)
    LEFT JOIN MasterIssFacilityArray iss 
        ON @Manual IN ('ISS_2001', 'ISS_2004')
        AND f.SubtypeCode IN (4, 5)
        AND iss.IssSurgicalGroup = f.IssSurgicalGroup
        AND iss.SubtypeCode = f.SubtypeCode
),

-- Section 7: Batch Multi-Surgery Complexity Ranking
ComplexityRanking AS (
    SELECT 
        SurgeryGuid,
        DateTimePerformed,
        Laterality,
        SurgeryApproach,
        YearOfService,
        RowNumber,
        ProcedureGuid,
        SameApproach,
        RowShiftType,
        RVSCode,
        SurgicalGroup,
        HCPCSCode,
        ExceptionGuid,
        PriceModifier,
        SubtypeCode,
        SubtypeName,
        IsBundledInPackage,
        BaseCalculatedValue,
        RawCatalogUnits,
        SoatSurgicalGroup, -- FIXED: Re-introduced missing column pass-through for Section 10
        IssSurgicalGroup,  -- FIXED: Re-introduced missing column pass-through for Section 10
        -- CRUCIAL COLOMBIAN COMPLIANCE FIX FOR BATCH LOOPS:
        -- Generates an isolated complexity sequence (1 to 7) per distinct surgical operation.
        ROW_NUMBER() OVER (
            PARTITION BY SurgeryGuid, SubtypeCode 
            ORDER BY RawCatalogUnits DESC, RowNumber ASC
        ) AS FinancialRank
    FROM CatalogBaseUnits
),
-- Section 8: Set-Based Surgical Degradation & Bilateral Multipliers
SurgicalDegradationRules AS (
    SELECT 
        r.*,
        CAST(
            CASE 
                -- Rule A: PRIMARY / MOST COMPLEX PROCEDURE WITHIN EACH SURGERY (FinancialRank = 1)
                -- Paid at 100%. If bilateral, applies professional (1.75x) or room (1.50x) modifiers.
                WHEN r.FinancialRank = 1 THEN 
                    CASE 
                        WHEN r.Laterality = 3 AND r.SubtypeCode IN (1, 2, 3) THEN 1.75 
                        WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 
                        ELSE 1.00 
                    END 
                    
                -- Rule B: SUBSEQUENT PROCEDURES - SAME SURGICAL APPROACH / SAME INCISION (SameApproach = 1)
                -- Professional fees drop to 50%, Room and Materials are unbillable ($0) as per regulation.
                WHEN r.FinancialRank > 1 AND r.SameApproach = 1 THEN
                    CASE 
                        WHEN r.SubtypeCode IN (1, 2, 3) THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                        WHEN r.SubtypeCode = 4 THEN 0.00         
                        WHEN r.SubtypeCode = 5 THEN 0.00         
                        ELSE 0.50 
                    END
                        
                -- Rule C: SUBSEQUENT PROCEDURES - DIFFERENT SURGICAL APPROACH (SameApproach = 0)
                -- SOAT pays at 100% face value, whereas ISS typically scales downstream items down to 75%.
                WHEN r.FinancialRank > 1 AND r.SameApproach = 0 THEN
                    CASE 
                        WHEN @Manual = 'SOAT' THEN 1.00 
                        ELSE 0.75 
                    END * CASE 
                            WHEN r.Laterality = 3 AND r.SubtypeCode IN (1, 2, 3) THEN 1.75 
                            WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50
                            ELSE 1.00 
                          END
                    
                ELSE 1.00
            END AS DECIMAL(10,4) -- Preserves precision thresholds for complex multi-procedure fractional splits
        ) AS DegradationMultiplier
    FROM ComplexityRanking r
),
-- Section 9: Set-Based Shift Surcharges & Annual Rate Binding
FinalShiftAdjustments AS (
    SELECT 
        d.*,
        -- STEP A: Apply a 25% premium for off-hours professional care (Night / Weekend Shifts)
        CAST(
            CASE 
                WHEN d.RowShiftType IN (3, 4) AND d.SubtypeCode IN (1, 2, 3) THEN 1.25 
                ELSE 1.00 
            END AS DECIMAL(10,4)
        ) AS ShiftMultiplier,
        
        -- STEP B: Identify legal unit basis required for final auditing trail per surgery date
        CASE 
            WHEN @Manual = 'SOAT' AND d.DateTimePerformed < '2024-01-01' THEN 'SMDLV'
            WHEN @Manual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 'UVB'
            WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN 'UVT' 
            ELSE 'COP' 
        END AS ValueBasis,
             
        -- STEP C: Bind the correct annual monetary rate matching each surgery's respective year
        CASE 
            WHEN @Manual = 'SOAT' AND d.DateTimePerformed < '2024-01-01' THEN 
                CASE d.YearOfService 
                    WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 0.00 
                END
            WHEN @Manual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 
                CASE d.YearOfService 
                    WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 ELSE 0.00 
                END
            WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN 
                CASE d.YearOfService 
                    WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 0.00 
                END
            ELSE 1.00 
        END AS UnitMonetaryValue
    FROM SurgicalDegradationRules d
),
-- Section 10: Multi-Surgery Transaction Ledger Insertion
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
    'Surgery',                          -- TransactionType explicitly categorized as surgical care lines
    @ClaimGuid,                         -- ClaimGuid mapped dynamically from Section 1's active selection
    f.SurgeryGuid, 
    @ContractGuid, 
    f.ExceptionGuid,                    -- ContractExceptionGuid tracking category matching lineage
    '04',                               -- Ambity set explicitly to outpatient surgical care code
    f.UnitMonetaryValue,                -- BaseUnitValue
    f.SubtypeName,                      -- SurgicalComponent (Surgeon, Anesthesiologist, etc.)
    f.SurgicalGroup, 
    f.SurgeryApproach,                  -- SurgicalApproach
    f.SameApproach, 
    f.RowShiftType,                     -- ShiftTypeApplied
    0.00,                               -- SurchargeAmount
    f.RVSCode,                          -- CupsCode
    NULL,                               -- CUMCode
    f.DateTimePerformed,                -- ExternalProcessedDateTime
    GETDATE(),                          -- DateTimeEntered tracking timestamp
    @Manual,                            -- RevenueCode tracking tariff manual code
    1,                                  -- Quantity
    f.FinancialRank,                    -- ItemCost (1-7 sequence complexity rank)
    f.Laterality,                       -- ItemSnomedCode (Laterality mapping code)
    f.RawCatalogUnits,                  -- ItemAlternateCode
    f.BaseCalculatedValue,              -- LocalAmount
    f.DegradationMultiplier,            -- USDBasePrice
    f.ShiftMultiplier,                  -- USDPerItemChargeAmount
    f.ValueBasis,                       -- PaymentType
    -- Core Financial Liquidation formula for unified percentage matrix rows
    CAST((f.RawCatalogUnits * f.BaseCalculatedValue * f.DegradationMultiplier * f.ShiftMultiplier * f.UnitMonetaryValue) AS DECIMAL(18,2)), -- NetAmount
    0.00,                               -- TaxAmount
    0.00,                               -- DiscountAmount
    CAST((f.RawCatalogUnits * f.BaseCalculatedValue * f.DegradationMultiplier * f.ShiftMultiplier * f.UnitMonetaryValue) AS DECIMAL(18,2)), -- PerItemChargeAmount
    'Active'                            -- [Status]
FROM FinalShiftAdjustments f;

-- Section 11: Set-Based Standalone Procedure Matrix Flattening
-- 11a. COMPLIANCE REGISTRY: Reuse the ColombianHolidays CTE definition from Section 3a.
-- 11b. Extract and calculate context time-of-care shift profiles for all active procedures row-by-row
OutpatientProcedureList AS (
    SELECT 
        pp.ProcedureGuid,
        pp.ProcedureCode,
        pp.ProcedureDescription,
        pp.LaterialityCode,
        pp.ServiceGroup,
        ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS TargetDate,
        YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) AS YearOfService,
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN (DATEPART(dw, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) + @@DATEFIRST + 5) % 7 + 1 IN (6, 7) THEN 4
            WHEN DATEPART(hour, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) < 7 THEN 3
            WHEN DATEPART(hour, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType
    FROM ClinicalGeniusEhr.dbo.PatientProcedures pp WITH(NOLOCK)
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS DATE)
    WHERE pp.PatientVisit = @PatientVisit 
      AND pp.Active = 1
),
-- Section 12: Standalone Exception Priority Scoring
-- 12a. Score and rank contract exceptions dynamically row-by-row for all procedures
AllMatchingProcedureExceptions AS (
    SELECT 
        opl.ProcedureGuid, opl.ProcedureCode, opl.ProcedureDescription, opl.LaterialityCode, opl.ServiceGroup, 
        opl.TargetDate, opl.YearOfService, opl.RowShiftType,
        ce.PriceModifier AS ExceptionPriceModifier, 
        ce.ExceptionGuid,
        -- Evaluate exception precision matching dynamically to establish priority per individual procedure
        ROW_NUMBER() OVER (
            PARTITION BY opl.ProcedureGuid
            ORDER BY CASE 
                WHEN ce.ShiftType = opl.RowShiftType AND ce.ServiceGroup = opl.ServiceGroup AND ce.SurgeryGroups = opl.ProcedureCode THEN 1
                WHEN ce.ShiftType = 1              AND ce.ServiceGroup = opl.ServiceGroup AND ce.SurgeryGroups = opl.ProcedureCode THEN 2
                WHEN ce.ShiftType = 1              AND ce.ServiceGroup = '00'            AND ce.SurgeryGroups = opl.ProcedureCode THEN 3
                WHEN ce.ShiftType = 1              AND ce.ServiceGroup = '00'            AND ce.SurgeryGroups IS NULL           THEN 4
                ELSE 5
            END ASC,
            ABS(ce.PriceModifier) DESC, 
            ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM OutpatientProcedureList opl
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = @ContractGuid 
        AND ce.Active = 1 
        AND CAST(opl.TargetDate AS DATE) >= ce.StartDate 
        AND CAST(opl.TargetDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        AND (ce.ShiftType = 1 OR ce.ShiftType = opl.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = opl.ServiceGroup) 
        AND (ce.SurgeryGroups IS NULL OR ce.SurgeryGroups = opl.ProcedureCode) 
),

-- 12b. Isolate only the absolute single highest scoring contract exception match per procedure
OutpatientAppliedExceptions AS ( -- FIXED: Changed alias name to prevent compiler duplicate identifier clash
    SELECT 
        ProcedureGuid, ProcedureCode, ProcedureDescription, LaterialityCode, ServiceGroup, 
        TargetDate, YearOfService, RowShiftType, ExceptionGuid,
        ISNULL(ExceptionPriceModifier, 0.00) AS PriceModifier
    FROM AllMatchingProcedureExceptions
    WHERE ExceptionPriorityRank = 1 
),

-- 13a. Embedded Inline Memory Array for Common Outpatient Diagnostic/Therapy Reference Weights
OutpatientTariffCatalogArray AS (
    SELECT ProcedureCode, RegulatedCatalogUnits
    FROM (VALUES
          (N'890201', 1.00)  -- Example: Standard First-Time Medical Consultation
        , (N'860101', 15.50) -- Example: Basic Non-Surgical Wound Treatment / Diagnostic
        , (N'902204', 0.85)  -- Example: Standard Outpatient Clinical Laboratory Panel
        , (N'871010', 2.10)  -- Example: Standard Diagnostic Chest X-Ray Tracking Line
        -- [Your team can append any additional standard test procedure codes here cleanly]
    ) OutpatientRows(ProcedureCode, RegulatedCatalogUnits)
),

-- 13b. Map catalog base units cleanly using the inline memory array
OutpatientBaseUnits AS (
    SELECT 
        pe.ProcedureGuid, pe.ProcedureCode, pe.ProcedureDescription, pe.LaterialityCode, pe.ServiceGroup, 
        pe.TargetDate, pe.YearOfService, pe.RowShiftType, pe.ExceptionGuid, pe.PriceModifier,
        -- Compute the unified percentage markup base factor from contract + exception layers
        CAST(1 + (@AdjustmentPct / 100.00) + (pe.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        
        -- Pull raw units safely by checking the inline array context
        CAST(
            CASE 
                -- If it maps inside our outpatient reference array, pull that regulated value
                WHEN arr.ProcedureCode IS NOT NULL THEN arr.RegulatedCatalogUnits
                
                -- Otherwise, fallback safely to standard COP face value basis (1.00 unit multiplier)
                ELSE 1.00 
            END AS DECIMAL(18,2)
        ) AS RawCatalogUnits
    FROM OutpatientAppliedExceptions pe -- FIXED: Pointed to the correct renamed outpatient source from Section 12
    -- Match directly against the inline memory array using the procedure code string
    LEFT JOIN OutpatientTariffCatalogArray arr 
        ON arr.ProcedureCode = pe.ProcedureCode
),

-- 13c. Apply shift multipliers and capture macro monetary conversion rates row-by-row
OutpatientFinalShiftAdjustments AS (
    SELECT 
        b.*,
        -- Apply a 25% premium for professional off-hours care (Night / Weekend Shifts)
        CAST(
            CASE 
                WHEN b.RowShiftType IN (3, 4) THEN 1.25 
                ELSE 1.00 
            END AS DECIMAL(10,4)
        ) AS ShiftMultiplier,
        
        -- Identify legal unit basis required for final auditing trail per procedure date
        CASE 
            WHEN @Manual = 'SOAT' AND b.TargetDate < '2024-01-01' THEN 'SMDLV'
            WHEN @Manual = 'SOAT' AND b.TargetDate >= '2024-01-01' THEN 'UVB'
            WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN 'UVT' 
            ELSE 'COP' 
        END AS ValueBasis,
        
        -- Bind the correct annual monetary rate matching each standalone item's respective year
        CASE 
            WHEN @Manual = 'SOAT' AND b.TargetDate < '2024-01-01' THEN 
                CASE b.YearOfService 
                    WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 0.00 
                END
            WHEN @Manual = 'SOAT' AND b.TargetDate >= '2024-01-01' THEN 
                CASE b.YearOfService 
                    WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 ELSE 0.00 
                END
            WHEN @Manual IN ('ISS_2001', 'ISS_2004') THEN 
                CASE b.YearOfService 
                    WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 0.00 
                END
            ELSE 1.00 
        END AS UnitMonetaryValue
    FROM OutpatientBaseUnits b
),
-- Section 14: Batch Standalone Procedure Ledger Insertion
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
    NULL,                               -- SurgeryGuid is NULL for non-surgical entries
    @ContractGuid, 
    f.ExceptionGuid, 
    '04',                               -- Ambity set explicitly to outpatient care code
    f.UnitMonetaryValue, 
    f.ProcedureDescription, 
    NULL,                               -- SurgicalGroup is omitted for standalone billing lines
    NULL,                               -- SurgicalApproach is omitted for non-surgical lines
    0,                                  -- SameApproach defaults to 0 for standalone entries
    f.RowShiftType,                     -- ShiftTypeApplied
    0.00,                               -- SurchargeAmount
    f.ProcedureCode, 
    NULL,                               -- CUMCode
    f.TargetDate, 
    GETDATE(),                          -- DateTimeEntered tracking timestamp
    @Manual,                            -- RevenueCode tracking tariff manual code
    1,                                  -- Quantity
    1,                                  -- ItemCost (Financial liquidation rank defaults to 1 for standalone items)
    f.LaterialityCode, 
    f.RawCatalogUnits, 
    f.BaseCalculatedValue, 
    1.00,                               -- USDBasePrice (Degradation multiplier defaults to 1.00 face value)
    f.ShiftMultiplier,                  -- USDPerItemChargeAmount (Shift surcharge factor applied)
    f.ValueBasis,
    -- Financial Liquidation formula for standalone procedure rows
    CAST((f.RawCatalogUnits * f.BaseCalculatedValue * f.ShiftMultiplier * f.UnitMonetaryValue) AS DECIMAL(18,2)), -- NetAmount
    0.00,                               -- TaxAmount
    0.00,                               -- DiscountAmount
    CAST((f.RawCatalogUnits * f.BaseCalculatedValue * f.ShiftMultiplier * f.UnitMonetaryValue) AS DECIMAL(18,2)), -- PerItemChargeAmount
    'Active'                            -- [Status]
FROM OutpatientFinalShiftAdjustments f;

-- Return confirmation metrics to the SaaS application layer
SELECT @@ROWCOUNT AS StandaloneProceduresPosted;









