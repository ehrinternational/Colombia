-- ==========================================================================================
-- COLOMBIA LIQUIDATION PRICING CORE ENGINE - VERSION 4.0 (SQL SERVER 2014 COMPLIANT)
-- PART 1: INITIALIZATION, CLEANUP, AND SURGICAL EXTRACTION MATRIX
-- ==========================================================================================

-- ==========================================================================================
-- SECTION 1: Visit-Wide Contract Context Extraction & Active Claim Validation Matrix
-- ==========================================================================================
-- Local variables for global visit context fallbacks
DECLARE @GlobalClaimGuid NVARCHAR(50) = NULL, 
        @GlobalContractGuid NVARCHAR(50) = NULL, 
        @GlobalManual VARCHAR(20) = NULL,
        @GlobalAdjustmentPct DECIMAL(5,2) = NULL;

-- 1a. Build an in-memory validation array of claims that are flag-active and unexpired.
-- Under Decreto 441 de 2022, a claim is only valid if its contract date boundaries encompass the active window.
DECLARE @ValidClaimsRegistry TABLE (
    ClaimGuid NVARCHAR(50) PRIMARY KEY,
    ContractGuid NVARCHAR(50),
    EntityCode VARCHAR(20),
    AdjustmentPct DECIMAL(5,2)
);

INSERT INTO @ValidClaimsRegistry (ClaimGuid, ContractGuid, EntityCode, AdjustmentPct)
SELECT 
    pyc.ClaimGuid,
    isc.ContractGuid,
    isc.EntityCode,
    isc.AdjustmentPct
FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) ON ppy.PatientPayerGuid = pyc.PayerGuid
INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) ON isc.ContractGuid = ppy.ContractGuid
WHERE pyc.PatientVisit = @PatientVisit
  AND pyc.Status = 'Pending'                -- Enforces that the claim hasn't been closed/billed yet
  AND pyc.FacilityId = @FacilityId           -- Multi-tenant isolation guard
  AND isc.Active = 1                         -- Contract must be explicitly flag-active
  AND CAST(GETDATE() AS DATE) >= isc.StartDate 
  AND CAST(GETDATE() AS DATE) <= ISNULL(isc.EndDate, '9999-12-31'); -- Enforces strict legal date boundaries

-- 1b. Resolve the PRIMARY global fallback claim context for the visit
SELECT TOP 1 
    @GlobalClaimGuid     = ClaimGuid,
    @GlobalContractGuid  = ContractGuid,
    @GlobalManual        = EntityCode,
    @GlobalAdjustmentPct = AdjustmentPct
FROM @ValidClaimsRegistry
ORDER BY ClaimGuid ASC; 

-- 1c. Safety Gate: Enforce Fallback Rules if no valid insurance baseline remains open
IF @GlobalClaimGuid IS NULL OR @GlobalManual IS NULL
BEGIN
    SET @GlobalClaimGuid = '00000000-0000-0000-0000-000000000000'; -- Unified Self-Pay Token Identifier
    SET @GlobalManual = 'SOAT';
    SET @GlobalAdjustmentPct = 25.00; -- Institutional retail markup percentage fallback
END;


-- ==========================================================================================
-- SECTION 2: Targeted Pre-Invoice Staging Soft-Clearance (Audit-Safe)
-- ==========================================================================================
-- Soft-clears previous staging rows to allow re-runs while fully preserving transmitted electronic invoice logs
UPDATE ClinicalGeniusSupplyChain.PatientTransactions WITH(ROWLOCK) 
SET Status = 'Canceled',
    DateTimeLastUpdated = GETDATE(),            
    LastUpdatedBy = 'PricingEngine'            
WHERE PatientVisit = @PatientVisit 
  -- Expanded to capture all potential Colombian billing categories to avoid orphaned records
  AND TransactionType IN ('Surgery', 'Procedure', 'Medication', 'Stay', 'RoomRights', 'Supplies', 'Honorary', 'BundleMaster')
  AND Status <> 'Canceled'                      -- Skip rows already canceled to optimize log writes
  AND Facility = @FacilityId                    -- Tenant protection anchor
  AND (ElectronicInvoiceStatus IS NULL OR ElectronicInvoiceStatus <> 'Transmitted');


-- ==========================================================================================
-- SECTION 3: Multi-Surgery Pipeline Matrix Execution
-- ==========================================================================================
-- 3a. COMPLIANCE REGISTRY: Official Colombian Legal Holidays (Projected 2026 - 2027)
;WITH ColombianHolidays AS (
    SELECT CAST(HolidayDate AS DATE) AS HolidayDate FROM (VALUES
        ('2026-01-01'),('2026-01-12'),('2026-03-23'),('2026-04-02'),('2026-04-03'),('2026-05-01'),('2026-06-02'),('2026-06-23'),('2026-06-30'),('2026-07-20'),('2026-08-07'),('2026-08-17'),('2026-10-12'),('2026-11-02'),('2026-11-16'),('2026-12-08'),('2026-12-25'),
        ('2027-01-01'),('2027-01-11'),('2027-03-22'),('2027-03-25'),('2027-03-26'),('2027-05-01'),('2027-05-10'),('2027-05-31'),('2027-06-07'),('2027-07-05'),('2027-07-12'),('2027-07-20'),('2027-08-07'),('2027-08-16'),('2027-10-18'),('2027-11-01'),('2027-11-15'),('2027-12-08'),('2027-12-25')
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
        , (9, 1, 8.01), (9, 2, 4.41), (9, 3, 2.13), (9, 4, 9.07), (9, 5, 6.07)
        , (10, 1, 9.53), (10, 2, 5.03), (10, 3, 2.53), (10, 4, 11.23), (10, 5, 7.15)
        , (11, 1, 11.45), (11, 2, 5.75), (11, 3, 3.03), (11, 4, 13.68), (11, 5, 8.52)
        , (12, 1, 13.91), (12, 2, 6.64), (12, 3, 3.67), (12, 4, 16.92), (12, 5, 10.38)
        , (13, 1, 17.14), (13, 2, 7.76), (13, 3, 4.51), (13, 4, 21.04), (13, 5, 12.87)
    ) ArrayRows(SurgicalGroup, SubtypeCode, BaseUnits)
),
-- 3c. Embedded Inline Memory Array for ISS Surgery Groups (20-23 Rooms & Materials)
MasterIssFacilityArray AS (
    SELECT IssSurgicalGroup, SubtypeCode, CAST(FacilityUvrPoints AS DECIMAL(18,2)) AS FacilityUvrPoints
    FROM (VALUES
          (20, 4, 55.00),  (20, 5, 40.00) 
        , (21, 4, 70.00),  (21, 5, 55.00) 
        , (22, 4, 105.00), (22, 5, 80.00) 
        , (23, 4, 145.00), (23, 5, 115.00)
    ) IssArrayRows(IssSurgicalGroup, SubtypeCode, FacilityUvrPoints)
),
-- 3d. Flatten surgical records and inject package metadata boundaries
ProcedureList AS (
    SELECT 
        s.SurgeryGuid, s.DateTimePerformed, s.Laterality, s.SurgeryApproach, s.SurgeonId, s.Anesthesiologist, s.SurgeonId2, s.SurgeonId3,
        YEAR(s.DateTimePerformed) AS YearOfService, v.RowNumber, v.ProcedureGuid, v.SameApproach,
        
        -- DYNAMIC ROW-LEVEL OVERRIDE PAYER RESOLUTION GATE
        -- Validates manual column override entries first against valid memory targets before falling back
        CASE WHEN val.ClaimGuid IS NOT NULL THEN s.ClaimGuid ELSE @GlobalClaimGuid END AS ResolvedClaimGuid,
        ISNULL(val.EntityCode, @GlobalManual) AS ResolvedManual,
        ISNULL(val.AdjustmentPct, @GlobalAdjustmentPct) AS ResolvedAdjustmentPct,

        -- Paquete Configuration Front-End Parameters Mapping
        CAST(ISNULL(s.IsBundle, 0) AS BIT) AS IsBundle,
        s.ProcedureGuid AS BundleCupsCode, s.BundleDescription, CAST(ISNULL(s.BundlePrice, 0.00) AS DECIMAL(18,2)) AS BundlePrice,
        CAST(ISNULL(s.SurgeonIncluded, 0) AS BIT) AS SurgeonIncluded, CAST(ISNULL(s.AnesthesiologistIncluded, 0) AS BIT) AS AnesthesiologistIncluded,
        CAST(ISNULL(s.AssistantIncluded, 0) AS BIT) AS AssistantIncluded, CAST(ISNULL(s.RoomIncluded, 0) AS BIT) AS RoomIncluded,
        CAST(ISNULL(s.MaterialIncluded, 0) AS BIT) AS MaterialIncluded, CAST(ISNULL(s.MedicationIncluded, 0) AS BIT) AS MedicationIncluded,
        
        -- Shift Mapping (Night / Holiday surcharge index tags)
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN DATEPART(weekday, s.DateTimePerformed) IN (6, 7) THEN 4 
            WHEN DATEPART(hour, s.DateTimePerformed) < 7 THEN 3 
            WHEN DATEPART(hour, s.DateTimePerformed) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType
    FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
    LEFT JOIN @ValidClaimsRegistry val ON val.ClaimGuid = s.ClaimGuid -- Real-time cross-contract checker
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(s.DateTimePerformed AS DATE)
    CROSS APPLY (VALUES 
          (1, s.PrimaryProcedure,   CAST(0 AS BIT)) 
        , (2, s.SecondaryProcedure, CAST(ISNULL(s.Incision2, 0) AS BIT))
        , (3, s.Procedure3,         CAST(ISNULL(s.Incision3, 0) AS BIT))
        , (4, s.Procedure4,         CAST(ISNULL(s.Incision4, 0) AS BIT))
        , (5, s.Procedure5,         CAST(ISNULL(s.Incision5, 0) AS BIT))
        , (6, s.Procedure6,         CAST(ISNULL(s.Incision6, 0) AS BIT))
        , (7, s.Procedure7,         CAST(ISNULL(s.Incision7, 0) AS BIT))
    ) v(RowNumber, ProcedureGuid, SameApproach)
    WHERE s.PatientVisit = @PatientVisit AND s.Status = 'Completed' AND s.Facility = @FacilityId AND v.ProcedureGuid IS NOT NULL
),
-- ==========================================================================================
-- SECTION 4: Code Mapping & Category Exception Priority Scoring
-- ==========================================================================================
ProceduresWithCodes AS (
    SELECT 
        pl.*,
        -- Resolves reference manuals dynamically row-by-row based on the row's assigned claim
        CASE 
             WHEN ISNULL(pl.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
             WHEN pl.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Value 
             ELSE mvx.ISS2004Value 
        END AS ManualValue,
        CASE 
             WHEN ISNULL(pl.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
             WHEN pl.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp 
             ELSE mvx.ISS2004SurgeryGrp 
        END AS SurgeryGroup,
        CASE 
             WHEN ISNULL(pl.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
             WHEN pl.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article 
             ELSE mvx.ISS2004Article 
        END AS ArticleGroup,
        pai.RVSCode AS CUPSCode
    FROM ProcedureList pl
    INNER JOIN ClinicalGeniusEhr.dbo.ProcedureAdministrationItems pai WITH(NOLOCK) 
        ON pl.ProcedureGuid = pai.ProcedureGuid 
    OUTER APPLY (
        SELECT TOP 1 
            SOATValue, ISS2001Value, ISS2004Value, 
            SOATSurgeryGrp, ISS2001SurgeryGrp, ISS2004SurgeryGrp, 
            SOATArticle, ISS2001Article, ISS2004Article
        FROM ClinicalGeniusSupplyChain.dbo.ManualValues mvl WITH(NOLOCK) 
        WHERE mvl.CUPSCode = pai.RVSCode 
          AND mvl.YearOfService = pl.YearOfService
    ) mvx
),
AllMatchingExceptions AS (
    SELECT 
        p.*, 
        ISNULL(ce.PriceModifier, 0.00) AS PriceModifier, 
        ce.ExceptionGuid,
        ROW_NUMBER() OVER (
            PARTITION BY p.SurgeryGuid, p.ProcedureGuid, p.RowNumber
            -- Evaluates exceptions against the specific row's ResolvedClaimGuid
            ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM ProceduresWithCodes p
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = (SELECT TOP 1 ContractGuid FROM @ValidClaimsRegistry WHERE ClaimGuid = p.ResolvedClaimGuid)
        AND ce.Active = 1 
        AND CAST(p.DateTimePerformed AS DATE) >= ce.StartDate 
        AND CAST(p.DateTimePerformed AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        AND ce.ArticleGroup = p.ArticleGroup
        AND (ce.ShiftType = 1 OR ce.ShiftType = p.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '04')
        AND (ce.SurgeryGrp IS NULL OR ce.SurgeryGrp = p.SurgeryGroup) 
),
ProceduresWithAppliedExceptions AS (
    SELECT a.* FROM AllMatchingExceptions a WHERE ExceptionPriorityRank = 1 
),

-- ==========================================================================================
-- SECTION 5: Batch Surgical Billing Pillar Splitting & Factor Evaluation
-- ==========================================================================================
FinalLineItemPricing AS (
    SELECT 
        pe.*, 
        v.SubtypeCode, 
        v.SubtypeName,
        -- Evaluates your surgery-specific screen checkboxes to determine package absorption
        CAST(
            CASE 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode = 1 AND pe.SurgeonIncluded = 1         THEN 1 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode = 2 AND pe.AnesthesiologistIncluded = 1 THEN 1 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode IN (3, 6) AND pe.AssistantIncluded = 1 THEN 1 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode = 4 AND pe.RoomIncluded = 1            THEN 1 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode = 5 AND pe.MaterialIncluded = 1        THEN 1 
                ELSE 0 
            END AS BIT
        ) AS IsBundledInPackage,
        CAST(1 + (ISNULL(pe.PriceModifier, 0.00) / 100.00) AS DECIMAL(10,4)) AS AppliedExceptionFactor
    FROM ProceduresWithAppliedExceptions pe
    CROSS APPLY (VALUES 
        (1, 'Cirujano'), 
        (2, 'Anestesiologo'), 
        (3, 'Ayudante'), 
        (4, 'Sala'), 
        (5, 'Materiales'), 
        (6, 'Segundo Ayudante')
    ) v(SubtypeCode, SubtypeName)
),
RemoveMissingStaff AS (
    SELECT rm.* FROM FinalLineItemPricing rm
    WHERE (rm.SubtypeCode = 2 AND rm.Anesthesiologist IS NOT NULL)
       OR (rm.SubtypeCode = 3 AND rm.SurgeonId2 IS NOT NULL)
       OR (rm.SubtypeCode = 6 AND rm.SurgeonId3 IS NOT NULL)
       OR rm.SubtypeCode IN (1, 4, 5) -- Preserves standard institutional facility fee baselines
),
-- ==========================================================================================
-- SECTION 6: Row Prioritization, Multi-Surgery Discounts & Unit Resolution
-- ==========================================================================================
-- 6a. Rank procedures by value STRICTLY within each independent surgical block session
SurgicalProcedureRanking AS (
    SELECT 
        f.*, 
        ROW_NUMBER() OVER (
            PARTITION BY f.SurgeryGuid, f.SubtypeCode 
            ORDER BY f.ManualValue DESC, f.ProcedureGuid ASC
        ) AS ProcedureValueRank
    FROM RemoveMissingStaff f 
),

-- 6b. Apply Colombian Multi-Surgery Discount Multipliers (Liquidación de Cirugías Múltiples)
SurgicalMultipliersApplied AS (
    SELECT 
        r.*,
        CAST(
            CASE 
                -- Primary procedure within this specific surgical block session is billed at 100%
                WHEN r.ProcedureValueRank = 1 THEN 1.00
                
                -- Same anatomical approach/incision (Vía de acceso idéntica)
                WHEN r.SameApproach = 1 AND r.ManualValue IS NOT NULL AND r.ResolvedManual = 'SOAT' THEN 0.70
                WHEN r.SameApproach = 1 AND r.ManualValue IS NOT NULL AND r.ResolvedManual LIKE 'ISS%' THEN 0.60
                
                -- Different anatomical approach/separate incision (Diferente vía de acceso)
                WHEN r.SameApproach = 0 AND r.ManualValue IS NOT NULL AND r.ResolvedManual = 'SOAT' THEN 0.75
                WHEN r.SameApproach = 0 AND r.ManualValue IS NOT NULL AND r.ResolvedManual LIKE 'ISS%' THEN 0.75
                
                ELSE 0.50 
            END AS DECIMAL(5,2)
        ) AS MultiSurgeryMultiplier
    FROM SurgicalProcedureRanking r
),

-- 6c. Consolidated Set-Based Unit Evaluator with Assistant Complexity Rules
CatalogBaseUnits AS (
    SELECT 
        f.*,
        CAST(
            CASE 
                -- Rule A: Package bundling baseline check (Forces absorbed sub-lines to exactly 0.00)
                WHEN f.IsBundledInPackage = 1 THEN 0.00
                
                -- Assistant Rules: First assistant is unbillable if the surgery is Group 5 or lower in SOAT
                WHEN f.ResolvedManual = 'SOAT' AND f.SubtypeCode = 3 AND f.SurgeryGroup <= 5 THEN 0.00
                
                -- Second Assistant Rule: Unbillable if the surgery is Group 10 or lower (Only valid for Groups 11-13)
                WHEN f.ResolvedManual = 'SOAT' AND f.SubtypeCode = 6 AND f.SurgeryGroup <= 10 THEN 0.00
                
                -- Rule B: SOAT Manual Evaluation (Resolves weight from embedded SOAT array)
                WHEN f.ResolvedManual = 'SOAT' THEN ISNULL(soat.BaseUnits, 0.00)
                
                -- Rule C: ISS Manual Professional Fees (Subtypes 1, 2, 3, and 6 map directly to row-level UVR values)
                WHEN f.ResolvedManual LIKE 'ISS%' AND f.SubtypeCode IN (1, 2, 3, 6) THEN ISNULL(f.ManualValue, 0.00)
                
                -- Rule D: ISS Manual Facility Fees (Subtypes 4, 5 resolve from embedded ISS array)
                WHEN f.ResolvedManual LIKE 'ISS%' AND f.SubtypeCode IN (4, 5) THEN ISNULL(iss.FacilityUvrPoints, 0.00)
                
                ELSE 0.00 
            END AS DECIMAL(18,2)
        ) AS RawCatalogUnits
    FROM SurgicalMultipliersApplied f 
    LEFT JOIN MasterSoatGroupsArray soat 
        ON f.ResolvedManual = 'SOAT' 
        AND soat.SurgicalGroup = f.SurgeryGroup 
        AND soat.SubtypeCode = CASE WHEN f.SubtypeCode = 6 THEN 3 ELSE f.SubtypeCode END
    LEFT JOIN MasterIssFacilityArray iss 
        ON f.ResolvedManual LIKE 'ISS%' 
        AND f.SubtypeCode IN (4, 5) 
        AND iss.IssSurgicalGroup = f.SurgeryGroup 
        AND iss.SubtypeCode = f.SubtypeCode
),

-- ==========================================================================================
-- SECTION 7: Batch Multi-Surgery Complexity Ranking
-- ==========================================================================================
ComplexityRanking AS (
    SELECT 
        cb.*, 
        ROW_NUMBER() OVER (
            PARTITION BY cb.SurgeryGuid, cb.SubtypeCode 
            ORDER BY cb.RawCatalogUnits DESC, cb.RowNumber ASC
        ) AS FinancialRank
    FROM CatalogBaseUnits cb
),
-- ==========================================================================================
-- SECTION 8: Set-Based Surgical Degradation & Bilateral Multipliers
-- ==========================================================================================
SurgicalDegradationRules AS (
    SELECT 
        r.*,
        CAST(
            CASE 
                -- Rule A: PRIMARY / MOST COMPLEX PROCEDURE WITHIN EACH SURGERY SESSION (FinancialRank = 1)
                -- Paid at 100%. Applies professional (1.75x) or room (1.50x) bilateral modifiers dynamically.
                WHEN r.FinancialRank = 1 THEN 
                    CASE 
                        WHEN r.Laterality = 3 AND r.SubtypeCode IN (1, 2, 3, 6) THEN 1.75 
                        WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 
                        ELSE 1.00 
                    END 
                    
                -- Rule B: SUBSEQUENT PROCEDURES - SAME SURGICAL APPROACH / SAME INCISION (SameApproach = 1)
                -- Professional fees drop to 50%, Room and Materials are unbillable ($0) as per regulation.
                WHEN r.FinancialRank > 1 AND r.SameApproach = 1 THEN
                    CASE 
                        WHEN r.SubtypeCode IN (1, 2, 3, 6) THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                        WHEN r.SubtypeCode = 4 THEN 0.00         
                        WHEN r.SubtypeCode = 5 THEN 0.00         
                        ELSE 0.50 
                    END
                        
                -- Rule C: SUBSEQUENT PROCEDURES - DIFFERENT SURGICAL APPROACH (SameApproach = 0)
                -- SOAT pays at 100% face value, whereas ISS typically scales downstream items down to 75%.
                WHEN r.FinancialRank > 1 AND r.SameApproach = 0 THEN
                    CASE WHEN r.ResolvedManual = 'SOAT' THEN 1.00 ELSE 0.75 END * 
                    CASE 
                        WHEN r.Laterality = 3 AND r.SubtypeCode IN (1, 2, 3, 6) THEN 1.75 
                        WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50
                        ELSE 1.00 
                    END
                    
                ELSE 1.00
            END AS DECIMAL(10,4) -- Preserves precision thresholds for complex multi-procedure fractional splits
        ) AS DegradationMultiplier
    FROM ComplexityRanking r
),

-- ==========================================================================================
-- SECTION 9: Set-Based Shift Surcharges & Annual Rate Binding
-- ==========================================================================================
FinalShiftAdjustments AS (
    SELECT 
        d.*,
        -- STEP A: Apply a 25% premium for off-hours professional care (Night / Weekend Shifts)
        CAST(
            CASE 
                WHEN d.RowShiftType IN (3, 4) AND d.SubtypeCode IN (1, 2, 3, 6) THEN 1.25 
                ELSE 1.00 
            END AS DECIMAL(10,4)) AS ShiftMultiplier,
        
        -- STEP B: Identify legal unit basis required for final auditing trail per surgery date
        CASE 
            WHEN d.ResolvedManual = 'SOAT' AND d.DateTimePerformed < '2024-01-01' THEN 'SMDLV'
            WHEN d.ResolvedManual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 'UVB'
            WHEN d.ResolvedManual LIKE 'ISS%' THEN 'UVR' 
            ELSE 'COP' 
        END AS ValueBasis,
             
        -- STEP C: Bind the correct annual monetary rate matching each surgery's respective year and contract
        CAST(
            CASE 
                -- Historical SOAT (Pre-2024 SMDLV baseline parameters)
                WHEN d.ResolvedManual = 'SOAT' AND d.DateTimePerformed < '2024-01-01' THEN 
                    CASE YEAR(d.DateTimePerformed)
                        WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 
                    END
                -- Modern SOAT (2024+ Ministry of Health UVB conversion allocations)
                WHEN d.ResolvedManual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 
                    CASE d.YearOfService 
                        WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 ELSE 12110.00 
                    END
                -- Unified ISS Contracts (Points mapped to corresponding contract year values)
                WHEN d.ResolvedManual LIKE 'ISS%' THEN 
                    CASE d.YearOfService 
                        WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 57540.00 
                    END
                ELSE 1.00 
            END AS DECIMAL(18,2)
        ) AS UnitMonetaryValue
    FROM SurgicalDegradationRules d
),
CalculatedLineItems AS (
    SELECT 
        f.*,
        -- STEP D: Final Total Line-Item Formulation (Resolves Double-Discounting & Bundle Suppression)
        -- Enforces FEV / RIPS 2026 standards: If a sub-component belongs to a bundle, the outward price drops to exactly 0.00
        CAST(
            CASE 
                WHEN f.IsBundledInPackage = 1 THEN 0.00
                ELSE (f.RawCatalogUnits * f.ShiftMultiplier * f.ResolvedAdjustmentPct * f.DegradationMultiplier * f.UnitMonetaryValue)
            END AS DECIMAL(18,2)
        ) AS CalculatedLineTotal
    FROM FinalShiftAdjustments f
)
-- ==========================================================================================
-- SECTION 10: Final Dual-Track Transaction Persistence Engine
-- ==========================================================================================

-- TRACK A: PERSIST INDIVIDUAL COMPONENT TRACKING LINES (ITEMIZED OR ZERO-VALUED BUNDLE ENTRIES)
INSERT INTO ClinicalGeniusSupplyChain.PatientTransactions (
    Facility, PatientId, PatientVisit, TransactionType, ClaimGuid, SurgeryGuid, ContractGuid, 
    BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, SameApproach, ShiftTypeApplied, 
    SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, DateTimeEntered, RevenueCode, 
    Quantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, USDBasePrice, 
    USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, PerItemChargeAmount, [Status]
)
SELECT 
    @FacilityId, 
    @PatientId, 
    @PatientVisit, 
    'Surgery' AS TransactionType,       
    f.ResolvedClaimGuid,                 -- FIXED: Persists the row-resolved claim instead of global fallback [1]
    f.SurgeryGuid, 
    @GlobalContractGuid,                               
    f.UnitMonetaryValue, 
    f.SubtypeName AS SurgicalComponent,                      
    f.SurgeryGroup, 
    f.SurgeryApproach,                  
    f.SameApproach, 
    f.RowShiftType AS ShiftTypeApplied,                     
    0.00 AS SurchargeAmount,                               
    f.CUPSCode,                         
    NULL AS CUMCode,                               
    f.DateTimePerformed AS ExternalProcessedDateTime,                
    GETDATE() AS DateTimeEntered,                          
    f.ResolvedManual AS RevenueCode,                            
    1 AS Quantity,                                  
    f.FinancialRank AS ItemCost,                    
    f.Laterality AS ItemSnomedCode,                       
    f.RawCatalogUnits AS ItemAlternateCode,                  
    f.ResolvedAdjustmentPct AS LocalAmount, 
    f.DegradationMultiplier AS USDBasePrice,            
    f.ShiftMultiplier AS USDPerItemChargeAmount,        
    f.ValueBasis AS PaymentType,                       
    f.CalculatedLineTotal AS NetAmount,                  -- Drops to 0.00 COP cleanly if pre-absorbed [1]
    0.00 AS TaxAmount,                               
    0.00 AS DiscountAmount,                               
    f.CalculatedLineTotal AS PerItemChargeAmount,       
    'Active' AS [Status]
FROM CalculatedLineItems f;


-- TRACK B: PERSIST MASTER PAQUETE/CANASTA FLAT-RATE LINES (SESSION ISOLATED)
INSERT INTO ClinicalGeniusSupplyChain.PatientTransactions (
    Facility, PatientId, PatientVisit, TransactionType, ClaimGuid, SurgeryGuid, ContractGuid, 
    BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, SameApproach, ShiftTypeApplied, 
    SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, DateTimeEntered, RevenueCode, 
    Quantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, USDBasePrice, 
    USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, PerItemChargeAmount, [Status]
)
SELECT 
    @FacilityId, 
    @PatientId, 
    @PatientVisit, 
    'BundleMaster' AS TransactionType, 
    f.ResolvedClaimGuid, 
    f.SurgeryGuid, 
    @GlobalContractGuid, 
    f.BundlePrice AS BaseUnitValue, 
    'Paquete Completo' AS SurgicalComponent, 
    NULL AS SurgicalGroup, 
    f.SurgeryApproach, 
    0 AS SameApproach, 
    1 AS ShiftTypeApplied, 
    0.00 AS SurchargeAmount, 
    f.BundleCupsCode AS CupsCode,       
    NULL AS CUMCode, 
    f.DateTimePerformed, 
    GETDATE() AS DateTimeEntered, 
    f.ResolvedManual AS RevenueCode, 
    1 AS Quantity, 
    0.00 AS ItemCost, 
    0 AS ItemSnomedCode, 
    NULL AS ItemAlternateCode, 
    f.BundlePrice AS LocalAmount, 
    1.00 AS USDBasePrice, 
    1.00 AS USDPerItemChargeAmount, 
    'COP' AS PaymentType, 
    f.BundlePrice AS NetAmount,         
    0.00 AS TaxAmount, 
    0.00 AS DiscountAmount, 
    f.BundlePrice AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM CalculatedLineItems f
WHERE f.IsBundle = 1                    
GROUP BY f.ResolvedClaimGuid, f.SurgeryGuid, f.BundleCupsCode, f.BundleDescription, f.BundlePrice, f.SurgeryApproach, f.DateTimePerformed;


-- ==========================================================================================
-- SECTION 10b: Inject High-Cost Carve-Out Surgical Charges from Existing Schema
-- ==========================================================================================
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
    'Supplies' AS TransactionType,          
    CASE WHEN val.ClaimGuid IS NOT NULL THEN sc.ClaimGuid ELSE @GlobalClaimGuid END AS ClaimGuid, -- Direct validator link
    CAST(sc.SurgeryGuid AS UNIQUEIDENTIFIER) AS SurgeryGuid, 
    @GlobalContractGuid, 
    NULL AS ContractExceptionGuid, 
    '04' AS Ambity, 
    CAST(ISNULL(sc.BasePrice, 0.00) AS DECIMAL(18,2)) AS BaseUnitValue, 
    ISNULL(sc.ItemDescription, sc.ItemName) AS SurgicalComponent, 
    NULL AS SurgicalGroup, 
    NULL AS SurgicalApproach, 
    0 AS SameApproach, 
    2 AS ShiftTypeApplied, 
    0.00 AS SurchargeAmount, 
    sc.ItemNumber AS CupsCode, 
    sc.ItemNumber AS CUMCode, 
    ISNULL(sc.DateTimeCompleted, s.DateTimePerformed) AS ExternalProcessedDateTime, 
    GETDATE() AS DateTimeEntered, 
    ISNULL(val.EntityCode, @GlobalManual) AS RevenueCode, 
    ISNULL(sc.Quantity, 1) AS Quantity, 
    CAST(ISNULL(sc.ItemCost, 0.00) AS DECIMAL(18,2)) AS ItemCost, 
    NULL AS ItemSnomedCode, 
    sc.ConsumedUOM AS ItemAlternateCode,    
    CAST(ISNULL(sc.ChargeBasePrice, 0.00) AS DECIMAL(10,4)) AS LocalAmount, 
    1.00 AS USDBasePrice, 
    1.00 AS USDPerItemChargeAmount, 
    'COP' AS PaymentType, 
    CAST(ISNULL(sc.NetAmount, 0.00) AS DECIMAL(18,2)) AS NetAmount, 
    CAST(ISNULL(sc.TaxAmount, 0.00) AS DECIMAL(18,2)) AS TaxAmount, 
    CAST(ISNULL(sc.DiscountAmount, 0.00) AS DECIMAL(18,2)) AS DiscountAmount, 
    CAST(ISNULL(sc.NetAmount, 0.00) AS DECIMAL(18,2)) AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM ClinicalGeniusEhr.dbo.ScheduledSurgeryCharges sc WITH(NOLOCK)
INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK) 
    ON CAST(s.SurgeryGuid AS VARCHAR(50)) = sc.SurgeryGuid
LEFT JOIN @ValidClaimsRegistry val ON val.ClaimGuid = sc.ClaimGuid -- Real-time cross-contract checker
WHERE s.PatientVisit = @PatientVisit 
  AND s.Status = 'Completed' 
  AND sc.Facility = @FacilityId 
  AND sc.Active = 1 
  AND ISNULL(sc.Billed, 0) = 0;

SELECT @@ROWCOUNT AS SurgicalLinesPosted;
-- ==========================================================================================
-- SECTION 12: Standalone Outpatient Exception Priority Scoring
-- ==========================================================================================
AllMatchingProcedureExceptions AS (
    SELECT 
        opl.*, 
        ce.PriceModifier AS ExceptionPriceModifier, 
        ce.ExceptionGuid,
        ROW_NUMBER() OVER (
            PARTITION BY opl.ProcedureGuid
            -- FIXED: Exception priority evaluation is explicitly driven by the row's assigned claim
            ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM OutpatientProcedureList opl
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = (SELECT TOP 1 ContractGuid FROM @ValidClaimsRegistry WHERE ClaimGuid = opl.ResolvedClaimGuid)
        AND ce.Active = 1 
        AND CAST(opl.TargetDate AS DATE) >= ce.StartDate 
        AND CAST(opl.TargetDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        AND ce.ArticleGroup = opl.ArticleGroup
        AND (ce.ShiftType = 1 OR ce.ShiftType = opl.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = opl.ServiceGroup) 
        AND (ce.SurgeryGrp IS NULL OR ce.SurgeryGrp = opl.SurgeryGroup) 
),
OutpatientAppliedExceptions AS ( 
    SELECT 
        ProcedureGuid, ProcedureCode, ProcedureDescription, LaterialityCode, ServiceGroup, 
        TargetDate, YearOfService, RowShiftType, ExceptionGuid, CatalogValue, Ambity,
        ResolvedClaimGuid, ResolvedManual, ResolvedAdjustmentPct,
        ISNULL(ExceptionPriceModifier, 0.00) AS PriceModifier 
    FROM AllMatchingProcedureExceptions
    WHERE ExceptionPriorityRank = 1 
),

-- ==========================================================================================
-- SECTION 13: Standalone Outpatient Unit Resolution & Rate Binding
-- ==========================================================================================
OutpatientBaseUnits AS (
    SELECT 
        pe.*, 
        CAST(1 + (pe.ResolvedAdjustmentPct / 100.00) + (pe.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        CAST(pe.CatalogValue AS DECIMAL(18,2)) AS RawCatalogUnits 
    FROM OutpatientAppliedExceptions pe 
),
OutpatientFinalShiftAdjustments AS (
    SELECT 
        b.*, 
        CAST(CASE WHEN b.RowShiftType IN (3, 4) THEN 1.25 ELSE 1.00 END AS DECIMAL(10,4)) AS ShiftMultiplier,
        CASE 
            WHEN b.ResolvedManual = 'SOAT' AND b.TargetDate < '2024-01-01' THEN 'SMDLV' 
            WHEN b.ResolvedManual = 'SOAT' AND b.TargetDate >= '2024-01-01' THEN 'UVB' 
            WHEN b.ResolvedManual LIKE 'ISS%' THEN 'UVR' 
            ELSE 'COP' 
        END AS ValueBasis,
        CAST(
            CASE 
                WHEN b.ResolvedManual LIKE 'ISS%' THEN 
                    CASE b.YearOfService WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 ELSE 57540.00 END 
                ELSE 
                    CASE b.YearOfService WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 ELSE 12110.00 END 
            END AS DECIMAL(18,2)
        ) AS UnitMonetaryValue
    FROM OutpatientBaseUnits b
),
CalculatedOutpatientLines AS (
    SELECT 
        o.*, 
        CAST(o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue * o.UnitMonetaryValue AS DECIMAL(18,2)) AS OutpatientLineTotal 
    FROM OutpatientFinalShiftAdjustments o
),

-- ==========================================================================================
-- SECTION 14: Batch Standalone Procedure Ledger Insertion
-- ==========================================================================================
INSERT INTO ClinicalGeniusSupplyChain.PatientTransactions (
    Facility, PatientId, PatientVisit, TransactionType, ClaimGuid, SurgeryGuid, ContractGuid, 
    Ambity, BaseUnitValue, SurgicalComponent, CupsCode, ExternalProcessedDateTime, DateTimeEntered, 
    RevenueCode, Quantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, USDBasePrice, 
    USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, PerItemChargeAmount, [Status]
)
SELECT 
    @FacilityId, 
    @PatientId, 
    @PatientVisit, 
    'Procedure' AS TransactionType, 
    f.ResolvedClaimGuid,                 -- LOCKED: Inserts the dynamic row-resolved claim parameter
    NULL AS SurgeryGuid, 
    @GlobalContractGuid, 
    f.Ambity, 
    f.UnitMonetaryValue, 
    f.ProcedureDescription, 
    f.ProcedureCode, 
    f.TargetDate, 
    GETDATE() AS DateTimeEntered, 
    f.ResolvedManual AS RevenueCode, 
    1 AS Quantity, 
    1 AS ItemCost, 
    f.LaterialityCode AS ItemSnomedCode, 
    f.RawCatalogUnits AS ItemAlternateCode, 
    f.BaseCalculatedValue AS LocalAmount, 
    1.00 AS USDBasePrice, 
    f.ShiftMultiplier AS USDPerItemChargeAmount, 
    f.ValueBasis AS PaymentType, 
    f.OutpatientLineTotal AS NetAmount, 
    0.00 AS TaxAmount, 
    0.00 AS DiscountAmount, 
    f.OutpatientLineTotal AS PerItemChargeAmount, 
    'Active' AS [Status] 
FROM CalculatedOutpatientLines f;
-- ==========================================================================================
-- SECTION 16: Batch Medication Transaction Ledger Insertion
-- ==========================================================================================
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
    'Medication' AS TransactionType,       
    f.ResolvedClaimGuid,                   -- FIXED: Maps the row-resolved validated claim parameters
    f.SurgeryGuid,                         
    @GlobalContractGuid, 
    f.ExceptionGuid, 
    ISNULL(f.Ambity, '02') AS Ambity,             
    f.FormularyBasePrice AS BaseUnitValue, 
    f.MedicationName AS SurgicalComponent, 
    NULL AS SurgicalGroup,                               
    NULL AS SurgicalApproach,                               
    0 AS SameApproach,                                  
    f.RowShiftType AS ShiftTypeApplied,  
    0.00 AS SurchargeAmount,                               
    f.MedicationCode AS CupsCode,          
    f.MedicationCode AS CUMCode,           
    f.TargetDate AS ExternalProcessedDateTime, 
    GETDATE() AS DateTimeEntered,                          
    @Manual AS RevenueCode,                            
    f.ActualDoseGiven AS Quantity,         
    f.FormularyUnitCost AS ItemCost,       
    NULL AS ItemSnomedCode,                               
    f.QuantityUnit AS ItemAlternateCode,   
    f.BaseCalculatedValue AS LocalAmount,  
    1.00 AS USDBasePrice,                               
    1.00 AS USDPerItemChargeAmount,                               
    'COP' AS PaymentType,                              
    f.MedicationLineTotal AS NetAmount,    -- Automatically drops to 0.00 COP if pre-absorbed
    0.00 AS TaxAmount,                               
    0.00 AS DiscountAmount,                               
    f.MedicationLineTotal AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM CalculatedMedicationLines f;


-- ==========================================================================================
-- SECTION 17: Set-Based Inpatient Stay (Estancias) Expansion and Calendar Splitting
-- ==========================================================================================
ExpandedStayDays AS (
    SELECT 
        hos.StayGuid,
        hos.PatientVisit,
        hos.BedCategoryCode,   
        hos.FacilityId,
        CAST(DATEADD(DAY, t.n, hos.AdmissionDateTime) AS DATE) AS StayCalendarDate,
        YEAR(DATEADD(DAY, t.n, hos.AdmissionDateTime)) AS YearOfService,
        
        -- DYNAMIC OVERRIDE VALIDATION GATES
        CASE WHEN val.ClaimGuid IS NOT NULL THEN hos.ClaimGuid ELSE @GlobalClaimGuid END AS ResolvedClaimGuid,
        ISNULL(val.EntityCode, @GlobalManual) AS ResolvedManual,
        ISNULL(val.AdjustmentPct, @GlobalAdjustmentPct) AS ResolvedAdjustmentPct
        
    FROM ClinicalGeniusEhr.dbo.PatientHospitalStays hos WITH(NOLOCK)
    LEFT JOIN @ValidClaimsRegistry val ON val.ClaimGuid = hos.ClaimGuid -- Direct row validator link
    INNER JOIN Tally t ON t.n <= DATEDIFF(DAY, hos.AdmissionDateTime, ISNULL(hos.DischargeDateTime, GETDATE()))
    WHERE hos.PatientVisit = @PatientVisit
      AND hos.Status = 'Completed'
      AND hos.FacilityId = @FacilityId
),

-- ==========================================================================================
-- SECTION 18: Bed Category Manual Resolution & Exception Matching
-- ==========================================================================================
StaysWithTariffBaselines AS (
    SELECT 
        es.*,
        CASE 
            WHEN ISNULL(es.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
            WHEN es.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Value
            ELSE mvx.ISS2004Value 
        END AS RoomCatalogUnits,
        CASE 
            WHEN ISNULL(es.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
            WHEN es.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article
            ELSE mvx.ISS2004Article 
        END AS ArticleGroup,
        CAST(
            CASE 
                WHEN EXISTS (
                    SELECT 1 FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
                    WHERE s.PatientVisit = es.PatientVisit
                      AND s.Status = 'Completed'
                      AND s.IsBundle = 1
                      AND s.RoomIncluded = 1
                      AND es.StayCalendarDate >= CAST(s.DateTimePerformed AS DATE)
                      AND es.StayCalendarDate <= CAST(DATEADD(DAY, 1, s.DateTimePerformed) AS DATE)
                ) THEN 1 
                ELSE 0 
            END AS BIT
        ) AS IsStayAbsorbedByBundle
    FROM ExpandedStayDays es
    OUTER APPLY (
        SELECT TOP 1 SOATValue, ISS2001Value, ISS2004Value, SOATArticle, ISS2001Article, ISS2004Article
        FROM ClinicalGeniusSupplyChain.dbo.ManualValues mvl WITH(NOLOCK)
        WHERE mvl.CUPSCode = es.BedCategoryCode AND mvl.YearOfService = es.YearOfService
    ) mvx
),
AllMatchingStayExceptions AS (
    SELECT 
        st.*,
        ISNULL(ce.PriceModifier, 0.00) AS PriceModifier,
        ce.ExceptionGuid,
        ROW_NUMBER() OVER (
            PARTITION BY st.StayGuid, st.StayCalendarDate
            ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.ExceptionGuid ASC
        ) AS ExceptionPriorityRank
    FROM StaysWithTariffBaselines st
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = (SELECT TOP 1 ContractGuid FROM @ValidClaimsRegistry WHERE ClaimGuid = st.ResolvedClaimGuid)
        AND ce.Active = 1 
        AND st.StayCalendarDate >= ce.StartDate 
        AND st.StayCalendarDate <= ISNULL(ce.EndDate, '9999-12-31') 
        AND ce.ArticleGroup = st.ArticleGroup
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '03') 
),

-- ==========================================================================================
-- SECTION 19: Mathematical Evaluation & Monetary Rate Integration
-- ==========================================================================================
CalculatedStayDays AS (
    SELECT 
        ex.*,
        CAST(1 + (ex.ResolvedAdjustmentPct / 100.00) + (ex.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        CASE 
            WHEN ex.ResolvedManual = 'SOAT' AND ex.StayCalendarDate < '2024-01-01' THEN 'SMDLV'
            WHEN ex.ResolvedManual = 'SOAT' AND ex.StayCalendarDate >= '2024-01-01' THEN 'UVB'
            WHEN ex.ResolvedManual LIKE 'ISS%' THEN 'UVR' 
            ELSE 'COP' 
        END AS ValueBasis,
        CAST(
            CASE 
                WHEN ex.ResolvedManual = 'SOAT' AND ex.StayCalendarDate < '2024-01-01' THEN 
                    CASE ex.YearOfService WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 END
                WHEN ex.ResolvedManual = 'SOAT' AND ex.StayCalendarDate >= '2024-01-01' THEN 
                    CASE ex.YearOfService WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 ELSE 12110.00 END
                WHEN ex.ResolvedManual LIKE 'ISS%' THEN 
                    CASE ex.YearOfService WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 ELSE 57540.00 END
                ELSE 1.00 
            END AS DECIMAL(18,2)
        ) AS UnitMonetaryValue
    FROM AllMatchingStayExceptions ex
    WHERE ex.ExceptionPriorityRank = 1
),
FinalStayLiquidationLines AS (
    SELECT 
        c.*,
        CAST(
            CASE 
                WHEN c.IsStayAbsorbedByBundle = 1 THEN 0.00
                ELSE (c.RoomCatalogUnits * c.BaseCalculatedValue * c.UnitMonetaryValue)
            END AS DECIMAL(18,2)
        ) AS DayLineNetAmount
    FROM CalculatedStayDays c
)

-- ==========================================================================================
-- SECTION 20: Inpatient Stay Transaction Ledger Aggregation Insertion
-- ==========================================================================================
-- Collects the night-by-night calendar expansions and posts itemized records.
-- Injects the row-resolved verified ClaimGuid tracking token per day slice context.

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
    'Stay' AS TransactionType,         -- Isolated as inpatient hospital room care lines
    f.ResolvedClaimGuid,               -- FIXED: Maps the persistent row-resolved split claim profiles
    NULL AS SurgeryGuid, 
    @GlobalContractGuid, 
    f.ExceptionGuid, 
    '03' AS Ambity,                    -- Outpatient Clinic vs Inpatient Ward indicator code
    f.UnitMonetaryValue, 
    'Día de Estancia Hosp: Category Code ' + f.BedCategoryCode, 
    NULL AS SurgicalGroup, 
    NULL AS SurgicalApproach, 
    0 AS SameApproach, 
    2 AS ShiftTypeApplied,             -- Standard day shift fallback for continuous stays
    0.00 AS SurchargeAmount, 
    f.BedCategoryCode AS CupsCode, 
    NULL AS CUMCode, 
    CAST(f.StayCalendarDate AS DATETIME), 
    GETDATE() AS DateTimeEntered, 
    f.ResolvedManual AS RevenueCode, 
    1 AS Quantity,                     -- Evaluated as individual bed nights for granular audit mapping
    0.00 AS ItemCost, 
    NULL AS ItemSnomedCode, 
    f.RoomCatalogUnits AS ItemAlternateCode, 
    f.BaseCalculatedValue AS LocalAmount, 
    1.00 AS USDBasePrice, 
    1.00 AS USDPerItemChargeAmount, 
    f.ValueBasis AS PaymentType, 
    f.DayLineNetAmount AS NetAmount,    -- Drops cleanly to 0.00 if pre-absorbed by a package
    0.00 AS TaxAmount, 
    0.00 AS DiscountAmount, 
    f.DayLineNetAmount AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM FinalStayLiquidationLines f;

SELECT @@ROWCOUNT AS InpatientStayDaysPosted;
-- ==========================================================================================
-- SECTION 21: Set-Based Lab/Pathology Panel Flattening and Base Matching
-- ==========================================================================================
CompletedLabPanels AS (
    SELECT 
        lto.OrderGuid,
        lto.CPTCode AS PanelCupsCode,      -- Maps your CPTCode column directly to the Colombian CUPS registry
        lto.CPTDescription AS PanelDescription,
        lto.PatientVisit,
        lto.Facility AS FacilityId,
        ISNULL(lto.PinDate, lto.DateTimeScheduled) AS CompletionDate, -- The legal point of execution for RIPS
        YEAR(ISNULL(lto.PinDate, lto.DateTimeScheduled)) AS YearOfService,
        ISNULL(amx.Ambity, '02') AS Ambity, -- Dynamic spatial department tracking fallback
        
        -- DYNAMIC OVERRIDE VALIDATION GATES
        -- Evaluates manual column overrides against legally valid memory targets before falling back
        CASE WHEN val.ClaimGuid IS NOT NULL THEN lto.ClaimGuid ELSE @GlobalClaimGuid END AS ResolvedClaimGuid,
        ISNULL(val.EntityCode, @GlobalManual) AS ResolvedManual,
        ISNULL(val.AdjustmentPct, @GlobalAdjustmentPct) AS ResolvedAdjustmentPct,
        
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN DATEPART(weekday, ISNULL(lto.PinDate, lto.DateTimeScheduled)) IN (6, 7) THEN 4 
            WHEN DATEPART(hour, ISNULL(lto.PinDate, lto.DateTimeScheduled)) < 7 THEN 3 
            WHEN DATEPART(hour, ISNULL(lto.PinDate, lto.DateTimeScheduled)) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType,
        CAST(
            CASE 
                WHEN EXISTS (
                    SELECT 1 FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
                    WHERE s.PatientVisit = lto.PatientVisit
                      AND s.Status = 'Completed'
                      AND s.IsBundle = 1
                      AND s.ProcedureIncluded = 1 
                      AND ISNULL(lto.PinDate, lto.DateTimeScheduled) >= s.DateTimePerformed
                      AND ISNULL(lto.PinDate, lto.DateTimeScheduled) <= DATEADD(HOUR, 6, s.DateTimePerformed)
                ) THEN 1 
                ELSE 0 
            END AS BIT
        ) AS IsLabAbsorbedByBundle
    FROM ClinicalGeniusEhr.dbo.PatientLabTestOrders lto WITH(NOLOCK)
    LEFT JOIN @ValidClaimsRegistry val ON val.ClaimGuid = lto.ClaimGuid -- Direct row validator link
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(ISNULL(lto.PinDate, lto.DateTimeScheduled) AS DATE)
    OUTER APPLY (
        SELECT TOP 1 DPT.Ambity 
        FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
        INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) ON DPT.DepartmentGuid = PDT.DepartmentGuid
        WHERE PDT.PatientVisit = lto.PatientVisit 
          AND ISNULL(lto.PinDate, lto.DateTimeScheduled) > PDT.StartDateTime 
          AND (ISNULL(lto.PinDate, lto.DateTimeScheduled) < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
        ORDER BY PDT.StartDateTime DESC
    ) amx
    WHERE lto.PatientVisit = @PatientVisit 
      AND lto.Status = 'Completed'         
      AND lto.Facility = @FacilityId        
      AND ISNULL(lto.ExistingCharge, 0) = 0 
),

-- ==========================================================================================
-- SECTION 22: Annual Rate Binding & Contract Exception Priority Matrix
-- ==========================================================================================
LabLinesWithTariffs AS (
    SELECT 
        cl.*,
        CASE 
            WHEN ISNULL(cl.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
            WHEN cl.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Value
            ELSE mvx.ISS2004Value 
        END AS CatalogValue,
        CASE 
            WHEN ISNULL(cl.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
            WHEN cl.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article
            ELSE mvx.ISS2004Article 
        END AS ArticleGroup,
        CASE 
            WHEN ISNULL(cl.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
            WHEN cl.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
            ELSE mvx.ISS2004SurgeryGrp 
        END AS SurgeryGroup
    FROM CompletedLabPanels cl
    OUTER APPLY (
        SELECT TOP 1 
            SOATValue, ISS2001Value, ISS2004Value,
            SOATArticle, ISS2001Article, ISS2004Article,
            SOATSurgeryGrp, ISS2001SurgeryGrp, ISS2004SurgeryGrp
        FROM ClinicalGeniusSupplyChain.dbo.ManualValues mvl WITH(NOLOCK)
        WHERE mvl.CUPSCode = cl.PanelCupsCode
          AND mvl.YearOfService = cl.YearOfService
    ) mvx
),
AllMatchingLabExceptions AS (
    SELECT 
        lt.*,
        ISNULL(ce.PriceModifier, 0.00) AS PriceModifier,
        ce.ExceptionGuid,
        ROW_NUMBER() OVER (
            PARTITION BY lt.OrderGuid
            ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.ExceptionGuid ASC
        ) AS ExceptionPriorityRank
    FROM LabLinesWithTariffs lt
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = (SELECT TOP 1 ContractGuid FROM @ValidClaimsRegistry WHERE ClaimGuid = lt.ResolvedClaimGuid)
        AND ce.Active = 1 
        AND CAST(lt.CompletionDate AS DATE) >= ce.StartDate 
        AND CAST(lt.CompletionDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        AND ce.ArticleGroup = lt.ArticleGroup
        AND (ce.ShiftType = 1 OR ce.ShiftType = lt.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = lt.Ambity)
),
CalculatedLabLines AS (
    SELECT 
        e.*,
        CAST(1 + (e.ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        CASE 
            WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate < '2024-01-01' THEN 'SMDLV'
            WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 'UVB'
            WHEN e.ResolvedManual LIKE 'ISS%' THEN 'UVR' 
            ELSE 'COP' 
        END AS ValueBasis,
        CAST(
            CASE 
                WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate < '2024-01-01' THEN 
                    CASE e.YearOfService WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 END
                WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 
                    CASE e.YearOfService WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 ELSE 12110.00 END
                WHEN e.ResolvedManual LIKE 'ISS%' THEN 
                    CASE e.YearOfService WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 ELSE 57540.00 END
                ELSE 1.00 
            END AS DECIMAL(18,2)
        ) AS UnitMonetaryValue
    FROM AllMatchingLabExceptions e
    WHERE e.ExceptionPriorityRank = 1
),
FinalLabLiquidation AS (
    SELECT 
        c.*,
        CAST(
            CASE 
                WHEN c.IsLabAbsorbedByBundle = 1 THEN 0.00
                ELSE (c.CatalogValue * c.BaseCalculatedValue * c.UnitMonetaryValue)
            END AS DECIMAL(18,2)
        ) AS PanelLineNetAmount
    FROM CalculatedLabLines c
)

-- ==========================================================================================
-- SECTION 23: Laboratory Staging Ledger Insertion
-- ==========================================================================================
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
    'Procedure' AS TransactionType,     
    f.ResolvedClaimGuid,               -- FIXED: Maps the row-resolved validated claim parameters
    NULL AS SurgeryGuid, 
    @GlobalContractGuid, 
    f.ExceptionGuid, 
    f.Ambity, 
    f.UnitMonetaryValue, 
    'Examen de Laboratorio/Patología: ' + f.PanelDescription, 
    NULL AS SurgicalGroup, 
    NULL AS SurgicalApproach, 
    0 AS SameApproach, 
    f.RowShiftType AS ShiftTypeApplied, 
    0.00 AS SurchargeAmount, 
    f.PanelCupsCode AS CupsCode, 
    NULL AS CUMCode, 
    f.CompletionDate, 
    GETDATE() AS DateTimeEntered, 
    f.ResolvedManual AS RevenueCode, 
    1 AS Quantity, 
    0.00 AS ItemCost, 
    f.OrderGuid AS ItemSnomedCode,     
    NULL AS ItemAlternateCode, 
    f.BaseCalculatedValue AS LocalAmount, 
    1.00 AS USDBasePrice, 
    1.00 AS USDPerItemChargeAmount, 
    f.ValueBasis AS PaymentType, 
    f.PanelLineNetAmount AS NetAmount,  
    0.00 AS TaxAmount, 
    0.00 AS DiscountAmount, 
    f.PanelLineNetAmount AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM FinalLabLiquidation f;

SELECT @@ROWCOUNT AS LabPanelsPosted;
-- ==========================================================================================
-- SECTION 24: Set-Based Diagnostic Imaging Flattening and Base Matching (Catalog Aligned)
-- ==========================================================================================
CompletedImagingOrders AS (
    SELECT 
        img.ImagingOrderGuid,
        ioi.CPTCode AS ImagingCupsCode,       
        img.ImagingOrderDescription AS ImagingDescription,
        img.PatientVisit,
        img.Facility AS FacilityId,
        ISNULL(img.DateTimeUpdated, img.DateTimeEntered) AS CompletionDate, 
        YEAR(ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) AS YearOfService,
        ISNULL(amx.Ambity, '02') AS Ambity,    
        
        -- DYNAMIC OVERRIDE VALIDATION GATES
        -- Cross-checks the manual record assignment against active contracts before engine resolution
        CASE WHEN val.ClaimGuid IS NOT NULL THEN img.ClaimGuid ELSE @GlobalClaimGuid END AS ResolvedClaimGuid,
        ISNULL(val.EntityCode, @GlobalManual) AS ResolvedManual,
        ISNULL(val.AdjustmentPct, @GlobalAdjustmentPct) AS ResolvedAdjustmentPct,
        
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN DATEPART(weekday, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) IN (6, 7) THEN 4 
            WHEN DATEPART(hour, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) < 7 THEN 3 
            WHEN DATEPART(hour, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType,
        CAST(
            CASE 
                WHEN EXISTS (
                    SELECT 1 FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
                    WHERE s.PatientVisit = img.PatientVisit
                      AND s.Status = 'Completed'
                      AND s.IsBundle = 1
                      AND s.ProcedureIncluded = 1 
                      AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) >= s.DateTimePerformed
                      AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) <= DATEADD(HOUR, 6, s.DateTimePerformed)
                ) THEN 1 
                ELSE 0 
            END AS BIT
        ) AS IsImagingAbsorbedByBundle
    FROM ClinicalGeniusEhr.dbo.PatientImagingOrders img WITH(NOLOCK)
    INNER JOIN ClinicalGeniusEhr.dbo.ImagingOrderItems ioi WITH(NOLOCK) ON ioi.ImageOrderItemGuid = img.ImageOrderItemGuid
    LEFT JOIN @ValidClaimsRegistry val ON val.ClaimGuid = img.ClaimGuid -- Direct row validator link
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(ISNULL(img.DateTimeUpdated, img.DateTimeEntered) AS DATE)
    OUTER APPLY (
        SELECT TOP 1 DPT.Ambity 
        FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
        INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) ON DPT.DepartmentGuid = PDT.DepartmentGuid
        WHERE PDT.PatientVisit = img.PatientVisit 
          AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) > PDT.StartDateTime 
          AND (ISNULL(img.DateTimeUpdated, img.DateTimeEntered) < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
        ORDER BY PDT.StartDateTime DESC
    ) amx
    WHERE img.PatientVisit = @PatientVisit 
      AND img.OrderStatus = 'Completed'     
      AND img.Facility = @FacilityId         
),

-- ==========================================================================================
-- SECTION 25: Annual Rate Binding & Contract Exception Priority Matrix (Imaging)
-- ==========================================================================================
ImagingLinesWithTariffs AS (
    SELECT 
        io.*,
        CASE 
            WHEN ISNULL(io.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
            WHEN io.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Value
            ELSE mvx.ISS2004Value 
        END AS CatalogValue,
        CASE 
            WHEN ISNULL(io.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
            WHEN io.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article
            ELSE mvx.ISS2004Article 
        END AS ArticleGroup,
        CASE 
            WHEN ISNULL(io.ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
            WHEN io.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
            ELSE mvx.ISS2004SurgeryGrp 
        END AS SurgeryGroup
    FROM CompletedImagingOrders io
    OUTER APPLY (
        SELECT TOP 1 
            SOATValue, ISS2001Value, ISS2004Value,
            SOATArticle, ISS2001Article, ISS2004Article,
            SOATSurgeryGrp, ISS2001SurgeryGrp, ISS2004SurgeryGrp
        FROM ClinicalGeniusSupplyChain.dbo.ManualValues mvl WITH(NOLOCK)
        WHERE mvl.CUPSCode = io.ImagingCupsCode
          AND mvl.YearOfService = io.YearOfService
    ) mvx
),
AllMatchingImagingExceptions AS (
    SELECT 
        im.*,
        ISNULL(ce.PriceModifier, 0.00) AS PriceModifier,
        ce.ExceptionGuid,
        ROW_NUMBER() OVER (
            PARTITION BY im.ImagingOrderGuid
            ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.ExceptionGuid ASC
        ) AS ExceptionPriorityRank
    FROM ImagingLinesWithTariffs im
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = (SELECT TOP 1 ContractGuid FROM @ValidClaimsRegistry WHERE ClaimGuid = im.ResolvedClaimGuid)
        AND ce.Active = 1 
        AND CAST(im.CompletionDate AS DATE) >= ce.StartDate 
        AND CAST(im.CompletionDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        AND ce.ArticleGroup = im.ArticleGroup
        AND (ce.ShiftType = 1 OR ce.ShiftType = im.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = im.Ambity)
),
CalculatedImagingLines AS (
    SELECT 
        e.*,
        CAST(1 + (e.ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        CASE 
            WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate < '2024-01-01' THEN 'SMDLV'
            WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 'UVB'
            WHEN e.ResolvedManual LIKE 'ISS%' THEN 'UVR' 
            ELSE 'COP' 
        END AS ValueBasis,
        CAST(
            CASE 
                WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate < '2024-01-01' THEN 
                    CASE e.YearOfService WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 END
                WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 
                    CASE e.YearOfService WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 ELSE 12110.00 END
                WHEN e.ResolvedManual LIKE 'ISS%' THEN 
                    CASE e.YearOfService WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 ELSE 57540.00 END
                ELSE 1.00 
            END AS DECIMAL(18,2)
        ) AS UnitMonetaryValue
    FROM AllMatchingImagingExceptions e
    WHERE e.ExceptionPriorityRank = 1
),
FinalImagingLiquidation AS (
    SELECT 
        c.*,
        CAST(
            CASE 
                WHEN c.IsImagingAbsorbedByBundle = 1 THEN 0.00
                ELSE (c.CatalogValue * c.BaseCalculatedValue * c.UnitMonetaryValue)
            END AS DECIMAL(18,2)
        ) AS ImagingLineNetAmount
    FROM CalculatedImagingLines c
)

-- ==========================================================================================
-- SECTION 26: Diagnostic Imaging Staging Ledger Insertion
-- ==========================================================================================
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
    'Procedure' AS TransactionType,     
    f.ResolvedClaimGuid,               -- FIXED: Maps the row-resolved validated claim parameters
    NULL AS SurgeryGuid, 
    @GlobalContractGuid, 
    f.ExceptionGuid, 
    f.Ambity, 
    f.UnitMonetaryValue, 
    'Procedimiento de Imagenología: ' + f.ImagingDescription, 
    NULL AS SurgicalGroup, 
    NULL AS SurgicalApproach, 
    0 AS SameApproach, 
    f.RowShiftType AS ShiftTypeApplied, 
    0.00 AS SurchargeAmount, 
    f.ImagingCupsCode AS CupsCode,       
    NULL AS CUMCode, 
    f.CompletionDate, 
    GETDATE() AS DateTimeEntered, 
    f.ResolvedManual AS RevenueCode, 
    1 AS Quantity, 
    0.00 AS ItemCost, 
    f.ImagingOrderGuid AS ItemSnomedCode, 
    NULL AS ItemAlternateCode, 
    f.BaseCalculatedValue AS LocalAmount, 
    1.00 AS USDBasePrice, 
    1.00 AS USDPerItemChargeAmount, 
    f.ValueBasis AS PaymentType, 
    f.ImagingLineNetAmount AS NetAmount,  
    0.00 AS TaxAmount, 
    0.00 AS DiscountAmount, 
    f.ImagingLineNetAmount AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM FinalImagingLiquidation f;

SELECT @@ROWCOUNT AS ImagingStudiesPosted;

-- ==========================================================================================
-- SECTION 27: Embedded Inline Statutory Co-Payment Capping Registry (Topes de Copagos)
-- ==========================================================================================
-- Evaluates the visit-wide context after all sub-tracks are posted to compute patient liabilities.
-- Incorporates Contributivo (A, B, C) and Subsidiado (S1, S2) zero-pricing exemptions.

DECLARE @PatientFinancialClass VARCHAR(5) = 'A',
        @MaxAllowedCopayPerEvent DECIMAL(18,2) = 99999999.99,
        @CurrentCalculatedVisitCopay DECIMAL(18,2) = 0.00;

-- SQL Server 2014 Native LTRIM(RTRIM()) String Truncation Protection
SELECT TOP 1 
    @PatientFinancialClass = UPPER(LTRIM(RTRIM(pat.FinancialClass)))
FROM ClinicalGeniusEhr.dbo.PatientTable pat WITH(NOLOCK)
WHERE pat.PatientId = @PatientId;

-- Resolves the statutory maximum limit according to current year rules
SET @MaxAllowedCopayPerEvent = CASE YEAR(GETDATE())
    -- 2026 Statutory Limits
    WHEN 2026 THEN 
        CASE @PatientFinancialClass
            WHEN 'A'  THEN 351210.00
            WHEN 'B'  THEN 1406670.00
            WHEN 'C'  THEN 2813340.00
            WHEN 'S1' THEN 0.00               -- Subsidiado Nivel 1: Completely Exempt
            WHEN 'S2' THEN 110450.00          -- Subsidiado Nivel 2: Capped flat rate maximum
            ELSE 351210.00
        END
    -- 2027 Projected Limits
    WHEN 2027 THEN 
        CASE @PatientFinancialClass
            WHEN 'A'  THEN 369800.00
            WHEN 'B'  THEN 1481200.00
            WHEN 'C'  THEN 2962400.00
            WHEN 'S1' THEN 0.00
            WHEN 'S2' THEN 116300.00
            ELSE 369800.00
        END
    ELSE 99999999.99 -- No cap fallback if year bounds fail
END;

SELECT TOP 1
    @CurrentCalculatedVisitCopay = ISNULL(pyc.Copay, 0.00) + ISNULL(pyc.MedicalCoinsurance, 0.00)
FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
WHERE pyc.ClaimGuid = @GlobalClaimGuid
  AND pyc.FacilityId = @FacilityId;


-- ==========================================================================================
-- SECTION 28: Co-Payment Cap Correction Rule & Balance Shifting
-- ==========================================================================================

IF @CurrentCalculatedVisitCopay > @MaxAllowedCopayPerEvent
BEGIN
    -- If patient liability exceeds legal caps, lock out-of-pocket at maximum allowed,
    -- and dynamically shift the remainder directly to the insurer's liability line under Decreto 1652.
    UPDATE pyc
    SET pyc.Copay = CASE WHEN @PatientFinancialClass = 'S1' THEN 0.00 ELSE @MaxAllowedCopayPerEvent END,
        pyc.MedicalCoinsurance = 0.00, -- Erase the excess variable coinsurance lines
        -- Shift the remaining unpaid balance onto the Payer's coverage calculation so the hospital gets paid
        pyc.PayerCoverageAmount = pyc.PayerCoverageAmount + (@CurrentCalculatedVisitCopay - @MaxAllowedCopayPerEvent),
        pyc.LastUpdatedBy = 'CopayCappingMatrix'
    FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc
    WHERE pyc.ClaimGuid = @GlobalClaimGuid
      AND pyc.FacilityId = @FacilityId;
      
    SELECT 'CO-PAYMENT CAPPED: Excess shifted to insurer' AS AuditStatus;
END
ELSE
BEGIN
    SELECT 'CO-PAYMENT WITHIN LEGAL LIMITS: No shift required' AS AuditStatus;
END;
GO

