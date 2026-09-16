-- ==========================================================================================
-- CLINICAL GENIUS LIQUIDATION ENGINE - SURGERY ISOLATED ARCHITECTURE (VERSION 4.0)
-- TARGET ARCHITECTURE: SQL Server Enterprise 2014 NATIVE
-- MULTI-TENANT AUDITING STRUCTURE: Scoped via @FacilityId and Unique Guids
-- ==========================================================================================

-- ==========================================================================================
-- SECTION 1: Visit-Wide Contract Context Extraction
-- ==========================================================================================
-- Parameters passed dynamically from your SaaS application layer orchestration
DECLARE @PatientVisit NVARCHAR(50), 
        @FacilityId NVARCHAR(50), 
        @PatientId NVARCHAR(50);

-- Initialize local parameters for unified contract context
DECLARE @ContractGuid NVARCHAR(50) = NULL, 
        @Manual VARCHAR(20) = NULL,          -- Hardened: Kept NULL to prevent silent Self-Pay leakages
        @AdjustmentPct DECIMAL(5,2) = NULL,  -- Hardened: Baseline pricing must be explicitly validated
        @ClaimGuid NVARCHAR(50) = NULL;

-- 1a. Extract active, pending primary contract variables for the visit
SELECT TOP 1 
    @ClaimGuid          = pyc.ClaimGuid,
    @ContractGuid       = ppy.ContractGuid,
    @Manual             = isc.EntityCode,
    @AdjustmentPct      = isc.AdjustmentPct
FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
    ON ppy.PatientPayerGuid = pyc.PayerGuid
INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
    ON isc.ContractGuid = ppy.ContractGuid
WHERE pyc.PatientVisit = @PatientVisit
  AND pyc.Status = 'Pending'
  AND pyc.FacilityId = @FacilityId -- Enforces strict tenant separation at the registry step
ORDER BY pyc.BatchNumber ASC; 

-- 1b. Safety Gate: Enforce Fallback Rules via Documented Application Logic
-- If no active contract is resolved, explicitly catch and route to the Self-Pay policy baseline
IF @ContractGuid IS NULL OR @Manual IS NULL
BEGIN
    SET @Manual = 'SOAT';
    SET @AdjustmentPct = 25.00; -- Explicitly documented 25% markup margin for private/uninsured patients
    
    -- NOTE: In production, consider uncommenting the line below to completely halt unsafe execution:
    -- RAISERROR('No active insurance contract context found for this visit.', 16, 1); RETURN;
END

-- ==========================================================================================
-- SECTION 2: Targeted Pre-Invoice Staging Soft-Clearance (Audit-Safe)
-- ==========================================================================================
-- Updates all active staging transactions to 'Canceled' instead of doing a hard delete to preserve audits

UPDATE ClinicalGeniusSupplyChain.PatientTransactions WITH(ROWLOCK) 
SET Status = 'Canceled',
    DateTimeLastUpdated = GETDATE(),            
    LastUpdatedBy = 'PricingEngine'            
WHERE PatientVisit = @PatientVisit 
  -- Expanded to capture all potential Colombian billing categories to avoid orphaned records
  AND TransactionType IN (
        'Surgery', 
        'Procedure', 
        'Medication', 
        'Stay',            -- For Internación / Habitaciones
        'RoomRights',      -- For Derechos de Sala (Surgical Rooms)
        'Supplies',        -- For Materiales de Sutura y Curación
        'Honorary',        -- For Professional Specialist Fees (Surgeon, Anesthesiologist)
        'BundleMaster'     -- Sweeps previous master Paquete/Canasta lines to prevent duplicate pricing
  )
  AND Status <> 'Canceled'                      -- Skip rows that are already canceled to optimize log writes
  AND Facility = @FacilityId                    -- Multi-tenant isolation guard
  -- CRITICAL SAFETY RAIL: Prevent modifying any line that has already been packaged or sent to MinSalud
  AND (ElectronicInvoiceStatus IS NULL OR ElectronicInvoiceStatus <> 'Transmitted');

-- ==========================================================================================
-- SECTION 3: Multi-Surgery Pipeline Matrix Execution
-- ==========================================================================================
-- 3a. COMPLIANCE REGISTRY: Official Colombian Legal Holidays (Projected 2024 - 2030)

;WITH ColombianHolidays AS (
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
-- ==========================================================================================
-- SECTION 3d: Flatten surgical records and inject package metadata boundaries
-- ==========================================================================================
ProcedureList AS (
    SELECT 
        s.SurgeryGuid, 
        s.DateTimePerformed, 
        s.Laterality, 
        s.SurgeryApproach,
        s.SurgeonId, 
        s.Anesthesiologist, 
        s.SurgeonId2, 
        s.SurgeonId3,
        YEAR(s.DateTimePerformed) AS YearOfService, 
        v.RowNumber, 
        v.ProcedureGuid, 
        v.SameApproach,
        -- Paquete Mapping Boundaries
        CAST(ISNULL(s.IsBundle, 0) AS BIT) AS IsBundle,
        s.ProcedureGuid AS BundleCupsCode,
        s.BundleDescription,
        CAST(ISNULL(s.BundlePrice, 0.00) AS DECIMAL(18,2)) AS BundlePrice,
        CAST(ISNULL(s.SurgeonIncluded, 0) AS BIT) AS SurgeonIncluded,
        CAST(ISNULL(s.AnesthesiologistIncluded, 0) AS BIT) AS AnesthesiologistIncluded,
        CAST(ISNULL(s.AssistantIncluded, 0) AS BIT) AS AssistantIncluded,
        CAST(ISNULL(s.RoomIncluded, 0) AS BIT) AS RoomIncluded,
        CAST(ISNULL(s.MaterialIncluded, 0) AS BIT) AS MaterialIncluded,
        CAST(ISNULL(s.MedicationIncluded, 0) AS BIT) AS MedicationIncluded,
        -- Colombian Shift & Holiday Logic
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN DATEPART(weekday, s.DateTimePerformed) IN (6, 7) THEN 4 
            WHEN DATEPART(hour, s.DateTimePerformed) < 7 THEN 3 
            WHEN DATEPART(hour, s.DateTimePerformed) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType
    FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(s.DateTimePerformed AS DATE)
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
      AND s.Facility = @FacilityId
      AND v.ProcedureGuid IS NOT NULL
),

-- ==========================================================================================
-- SECTION 4: Code Mapping & Category Exception Priority Scoring
-- ==========================================================================================

ProceduresWithCodes AS (
    SELECT 
        pl.SurgeryGuid, 
        pl.DateTimePerformed, pl.Laterality, pl.SurgeryApproach, pl.YearOfService,
        pl.RowNumber, pl.ProcedureGuid, pl.SameApproach, pl.RowShiftType, 
        pl.SurgeonId, pl.Anesthesiologist, pl.SurgeonId2, pl.SurgeonId3,
        pl.IsBundle, pl.BundleCupsCode, pl.BundleDescription, pl.BundlePrice,
        pl.SurgeonIncluded, pl.AnesthesiologistIncluded, pl.AssistantIncluded,
        pl.RoomIncluded, pl.MaterialIncluded, pl.MedicationIncluded,
        
        -- Set the manual value dynamically matching the selected year of service
        CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
             WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Value
             ELSE mvx.ISS2004Value END AS ManualValue,
        -- Set the surgery group
        CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
             WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
             ELSE mvx.ISS2004SurgeryGrp END AS SurgeryGroup,
        -- Set the article 
        CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
             WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Article
             ELSE mvx.ISS2004Article END AS ArticleGroup,
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
            ORDER BY ce.Ranking DESC,
                     ABS(ce.PriceModifier) DESC, 
                     ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM ProceduresWithCodes p
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = @ContractGuid 
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
        -- Evaluates your new surgery-specific flags to drop patient-facing charges to $0.00
        CAST(
            CASE 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode = 1 AND pe.SurgeonIncluded = 1         THEN 1 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode = 2 AND pe.AnesthesiologistIncluded = 1 THEN 1 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode IN (3, 6) AND pe.AssistantIncluded = 1 THEN 1 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode = 4 AND pe.RoomIncluded = 1            THEN 1 
                WHEN pe.IsBundle = 1 AND v.SubtypeCode = 5 AND pe.MaterialIncluded = 1        THEN 1 
                -- MedicationIncluded can be evaluated here if you store multi-source intraop drug entries
                ELSE 0 
            END AS BIT
        ) AS IsBundledInPackage,
        
        -- Master Multiplier: Combines Payer baseline adjustments with target Contract Exceptions
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
    -- Safely removes professional fee lines if the supporting medical staff was not part of the clinical case
    SELECT rm.*
    FROM FinalLineItemPricing rm
    WHERE (rm.SubtypeCode = 2 AND rm.Anesthesiologist IS NOT NULL)
       OR (rm.SubtypeCode = 3 AND rm.SurgeonId2 IS NOT NULL)
       OR (rm.SubtypeCode = 6 AND rm.SurgeonId3 IS NOT NULL)
       OR rm.SubtypeCode IN (1, 4, 5) -- Always preserve Surgeon, Room, and Material lines
)

-- ==========================================================================================
-- SECTION 6: Row Prioritization, Multi-Surgery Discounts & Unit Resolution
-- ==========================================================================================
-- 6a. Rank procedures by value STRICTLY within each independent surgical block session

SurgicalProcedureRanking AS (
    SELECT 
        f.*,
        ROW_NUMBER() OVER (
            PARTITION BY f.SurgeryGuid, f.SubtypeCode -- FIXED: Isoles independent operating room blocks
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
                -- Primary procedure within THIS specific surgical session block is billed at 100% face value
                WHEN r.ProcedureValueRank = 1 THEN 1.00
                
                -- Same anatomical approach/incision within this session (Vía de acceso idéntica)
                WHEN r.SameApproach = 1 AND r.ManualValue IS NOT NULL AND @Manual = 'SOAT' THEN 0.70
                WHEN r.SameApproach = 1 AND r.ManualValue IS NOT NULL AND @Manual LIKE 'ISS%' THEN 0.60
                
                -- Different anatomical approach/separate incision within this session (Diferente vía de acceso)
                WHEN r.SameApproach = 0 AND r.ManualValue IS NOT NULL AND @Manual = 'SOAT' THEN 0.75
                WHEN r.SameApproach = 0 AND r.ManualValue IS NOT NULL AND @Manual LIKE 'ISS%' THEN 0.75
                
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
                -- Rule A: Package bundling baseline check (Forces outward tracking lines to exactly 0.00)
                WHEN f.IsBundledInPackage = 1 THEN 0.00
                
                -- Assistant Rules: First assistant is unbillable if the surgery is Group 5 or lower in SOAT
                WHEN @Manual = 'SOAT' AND f.SubtypeCode = 3 AND f.SurgeryGroup <= 5 THEN 0.00
                
                -- Second Assistant Rule: Unbillable if the surgery is Group 10 or lower (Only valid for Groups 11-13)
                WHEN @Manual = 'SOAT' AND f.SubtypeCode = 6 AND f.SurgeryGroup <= 10 THEN 0.00
                
                -- Rule B: SOAT Manual Evaluation (Resolves weight from embedded SOAT array)
                WHEN @Manual = 'SOAT' THEN ISNULL(soat.BaseUnits, 0.00)
                
                -- Rule C: ISS Manual Professional Fees (Subtypes 1, 2, 3, and 6 map directly to row-level UVR values)
                WHEN @Manual LIKE 'ISS%' AND f.SubtypeCode IN (1, 2, 3, 6) THEN ISNULL(f.ManualValue, 0.00)
                
                -- Rule D: ISS Manual Facility Fees (Subtypes 4, 5 resolve from embedded ISS array)
                WHEN @Manual LIKE 'ISS%' AND f.SubtypeCode IN (4, 5) THEN ISNULL(iss.FacilityUvrPoints, 0.00)
                
                ELSE 0.00 
            END AS DECIMAL(18,2)
        ) AS RawCatalogUnits
    FROM SurgicalMultipliersApplied f 
    LEFT JOIN MasterSoatGroupsArray soat 
        ON @Manual = 'SOAT' 
        AND soat.SurgicalGroup = f.SurgeryGroup 
        -- Second assistant links to SubtypeCode = 3 in the master array to inherit identical base units
        AND soat.SubtypeCode = CASE WHEN f.SubtypeCode = 6 THEN 3 ELSE f.SubtypeCode END
    LEFT JOIN MasterIssFacilityArray iss 
        ON @Manual LIKE 'ISS%'
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
        -- FIXED: Generates an isolated complexity sequence (1 to 7) per distinct surgical session block
        ROW_NUMBER() OVER (
            PARTITION BY cb.SurgeryGuid, cb.SubtypeCode -- FIXED: Session-aware segmentation
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
                -- SOAT pays at 100% face value, whereas ISS versions dynamically scale downstream items down to 75%.
                WHEN r.FinancialRank > 1 AND r.SameApproach = 0 THEN
                    -- FIXED: Swapped exact string match to a wildcard pattern to properly evaluate ISS_2001 and ISS_2004 versions
                    CASE WHEN @Manual LIKE 'ISS%' THEN 0.75 ELSE 1.00 END * 
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
            END AS DECIMAL(10,4)
        ) AS ShiftMultiplier,
        
        -- STEP B: Identify legal unit basis required for final auditing trail per surgery date
        CASE 
            WHEN @Manual = 'SOAT' AND d.DateTimePerformed < '2024-01-01' THEN 'SMDLV'
            WHEN @Manual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 'UVB'
            WHEN @Manual LIKE 'ISS%' THEN 'UVR' -- FIXED: Swapped text literal to wildcard to recognize ISS_2001/ISS_2004
            ELSE 'COP' 
        END AS ValueBasis,
             
        -- STEP C: Bind the correct annual monetary rate matching each surgery's respective year
        -- NOTE: To fully transition to your dynamic lookup table model, these static CASE parameters 
        -- should eventually be fetched out of an independent UnitParameters configuration entity.
        CAST(
            CASE 
                -- Historical SOAT (Pre-2024 SMDLV baseline parameters)
                WHEN @Manual = 'SOAT' AND d.DateTimePerformed < '2024-01-01' THEN 
                    CASE YEAR(d.DateTimePerformed)
                        WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 
                    END
                -- Modern SOAT (2024+ Ministry of Health UVB conversion allocations)
                WHEN @Manual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 
                    CASE d.YearOfService 
                        WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 ELSE 12110.00 
                    END
                -- Unified ISS Contracts (Points mapped to corresponding contract year values)
                WHEN @Manual LIKE 'ISS%' THEN -- FIXED: Enforced wildcard coverage for multi-year ISS frameworks
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
        -- Enforces Resolution 948 de 2026 FEV standards: If a sub-component belongs to a bundle 
        -- and its inclusion flag is matched, the final outward ledger price drops to exactly 0.00.
        CAST(
            CASE 
                WHEN f.IsBundledInPackage = 1 THEN 0.00
                ELSE (f.RawCatalogUnits * f.ShiftMultiplier * f.AppliedExceptionFactor * f.DegradationMultiplier * f.UnitMonetaryValue)
            END AS DECIMAL(18,2)
        ) AS CalculatedLineTotal
    FROM FinalShiftAdjustments f
)


-- ==========================================================================================
-- SECTION 10: Multi-Surgery Transaction Ledger Insertion (Dual-Track Persistence Engine)
-- ==========================================================================================

-- TRACK A: PERSIST INDIVIDUAL COMPONENT TRACKING LINES (ITEMIZED OR ZERO-VALUED BUNDLE ENTRIES)
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
    'Surgery' AS TransactionType,       
    @ClaimGuid,                         
    f.SurgeryGuid, 
    @ContractGuid, 
    f.ExceptionGuid,                    
    '04' AS Ambity,                               
    f.UnitMonetaryValue,                
    f.SubtypeName AS SurgicalComponent,                      
    f.SurgeryGroup, 
    f.SurgeryApproach,                  
    f.SameApproach, 
    f.RowShiftType,                     
    0.00 AS SurchargeAmount,                               
    f.CUPSCode,                         
    NULL AS CUMCode,                               
    f.DateTimePerformed,                
    GETDATE() AS DateTimeEntered,                          
    @Manual AS RevenueCode,                            
    1 AS Quantity,                                  
    f.FinancialRank AS ItemCost,                    
    f.Laterality AS ItemSnomedCode,                       
    f.RawCatalogUnits AS ItemAlternateCode,                  
    f.AppliedExceptionFactor AS LocalAmount,              -- FIXED: Maps true exception scale factor, bypassing 6b glitch
    f.DegradationMultiplier AS USDBasePrice,            
    f.ShiftMultiplier AS USDPerItemChargeAmount,        
    f.ValueBasis AS PaymentType,                       
    f.CalculatedLineTotal AS NetAmount,                 -- Drops to 0.00 natively if IsBundledInPackage = 1
    0.00 AS TaxAmount,                               
    0.00 AS DiscountAmount,                               
    f.CalculatedLineTotal AS PerItemChargeAmount,       
    'Active' AS [Status]
FROM CalculatedLineItems f;

-- TRACK B: PERSIST MASTER PAQUETE/CANASTA FLAT-RATE LINES (EXECUTED ONCE PER DISTINCT BUNDLED SURGERY)
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
    'BundleMaster' AS TransactionType, -- Differentiates the row as a master contract package flat fee
    @ClaimGuid, 
    f.SurgeryGuid, 
    @ContractGuid, 
    NULL AS ContractExceptionGuid, 
    '04' AS Ambity, 
    f.BundlePrice AS BaseUnitValue, 
    'Paquete Completo' AS SurgicalComponent, 
    NULL AS SurgicalGroup, 
    f.SurgeryApproach, 
    0 AS SameApproach, 
    1 AS ShiftTypeApplied, 
    0.00 AS SurchargeAmount, 
    f.BundleCupsCode AS CupsCode,       -- Captures the primary comprehensive surgical CUPS code
    NULL AS CUMCode, 
    f.DateTimePerformed, 
    GETDATE() AS DateTimeEntered, 
    @Manual AS RevenueCode, 
    1 AS Quantity, 
    0.00 AS ItemCost, 
    0 AS ItemSnomedCode, 
    NULL AS ItemAlternateCode, 
    f.BundlePrice AS LocalAmount, 
    1.00 AS USDBasePrice, 
    1.00 AS USDPerItemChargeAmount, 
    'COP' AS PaymentType, 
    f.BundlePrice AS NetAmount,         -- Resolves the full negotiated flat contract rate
    0.00 AS TaxAmount, 
    0.00 AS DiscountAmount, 
    f.BundlePrice AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM CalculatedLineItems f
WHERE f.IsBundle = 1                    -- Safety Fence: Only executes if the surgery is configured as a bundle
GROUP BY f.SurgeryGuid, f.BundleCupsCode, f.BundleDescription, f.BundlePrice, f.SurgeryApproach, f.DateTimePerformed;

SELECT @@ROWCOUNT AS SurgicalLinesPosted;
GO

-- ==========================================================================================
-- SECTION 10b: Inject High-Cost Carve-Out Surgical Charges from Existing Schema
-- ==========================================================================================
-- Reads from ScheduledSurgeryCharges to inject items explicitly excluded from the flat bundle.
-- Maps to ModalidadPago '02' (Pago por Evento) for precise Carvajal/RIPS 2026 validation.

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
    'Supplies' AS TransactionType,          -- Categorized as separately billable surgical supplies
    @ClaimGuid,
    CAST(sc.SurgeryGuid AS UNIQUEIDENTIFIER), -- Explicitly bound back to parent surgical session block
    @ContractGuid,
    NULL AS ContractExceptionGuid,          -- Financial rules are pre-calculated at line entry level
    '04' AS Ambity,                         -- Scoped to the surgical outpatient care window
    CAST(ISNULL(sc.BasePrice, 0.00) AS DECIMAL(18,2)) AS BaseUnitValue,
    ISNULL(sc.ItemDescription, sc.ItemName) AS SurgicalComponent,
    NULL AS SurgicalGroup,
    NULL AS SurgicalApproach,
    0 AS SameApproach,
    2 AS ShiftTypeApplied,                  -- Standard day shift fallback for continuous entries
    0.00 AS SurchargeAmount,
    sc.ItemNumber AS CupsCode,             -- Maps your master item number as the billing identifier
    sc.ItemNumber AS CUMCode,              -- Matches official CUM identifier track for pharmaceutical lines
    ISNULL(sc.DateTimeCompleted, s.DateTimePerformed) AS ExternalProcessedDateTime,
    GETDATE() AS DateTimeEntered,
    @Manual AS RevenueCode,
    ISNULL(sc.Quantity, 1) AS Quantity,
    CAST(ISNULL(sc.ItemCost, 0.00) AS DECIMAL(18,2)) AS ItemCost, -- Preserves true warehouse acquisition cost
    NULL AS ItemSnomedCode,
    sc.ConsumedUOM AS ItemAlternateCode,    -- Captures physical presentation values (e.g., 'Mg', 'Vial')
    CAST(ISNULL(sc.ChargeBasePrice, 0.00) AS DECIMAL(10,4)) AS LocalAmount,
    1.00 AS USDBasePrice,
    1.00 AS USDPerItemChargeAmount,
    'COP' AS PaymentType,                   -- Settles explicitly as corporate local currency track
    CAST(ISNULL(sc.NetAmount, 0.00) AS DECIMAL(18,2)) AS NetAmount, -- True pre-calculated total billable value
    CAST(ISNULL(sc.TaxAmount, 0.00) AS DECIMAL(18,2)) AS TaxAmount,
    CAST(ISNULL(sc.DiscountAmount, 0.00) AS DECIMAL(18,2)) AS DiscountAmount,
    CAST(ISNULL(sc.NetAmount, 0.00) AS DECIMAL(18,2)) AS PerItemChargeAmount,
    'Active' AS [Status]
FROM ClinicalGeniusEhr.dbo.ScheduledSurgeryCharges sc WITH(NOLOCK)
INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK) 
    ON CAST(s.SurgeryGuid AS VARCHAR(50)) = sc.SurgeryGuid
WHERE s.PatientVisit = @PatientVisit
  AND s.Status = 'Completed'
  AND sc.Facility = @FacilityId             -- Multi-tenant isolation guard
  AND sc.Active = 1                         -- Ensures only active, un-deleted lines are transported
  AND ISNULL(sc.Billed, 0) = 0;             -- Safeguard against double-billing processed rows

SELECT @@ROWCOUNT AS HighCostCarveOutsPosted;

-- ==========================================================================================
-- SECTION 11: Set-Based Standalone Procedure Matrix Flattening
-- ==========================================================================================
-- 11a. COMPLIANCE REGISTRY: Official Colombian Legal Holidays (Projected 2024 - 2030)

;WITH ColombianHolidays AS (
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

OutpatientProcedureList AS (
    SELECT 
        pp.ProcedureGuid, pp.ProcedureCode, pp.ProcedureDescription, pp.LaterialityCode, pp.ServiceGroup,
        ISNULL(amx.Ambity, '01') AS Ambity, -- Fallback defaults to standard Consultorio Outpatient context
        -- Set the manual value dynamically matching the selected year of service
        CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
             WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Value
             ELSE mvx.ISS2004Value END AS CatalogValue,
        -- Set the surgery group
        CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
             WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
             ELSE mvx.ISS2004SurgeryGrp END AS SurgeryGroup,
        -- Set the article 
        CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
             WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Article
             ELSE mvx.ISS2004Article END AS ArticleGroup,
        ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS TargetDate,
        YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) AS YearOfService,
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN DATEPART(weekday, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) IN (6, 7) THEN 4 
            WHEN DATEPART(hour, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) < 7 THEN 3 
            WHEN DATEPART(hour, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType
    FROM ClinicalGeniusEhr.dbo.PatientProcedures pp WITH(NOLOCK)
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS DATE)
    OUTER APPLY (
        SELECT TOP 1 DPT.Ambity 
        FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
        INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) ON DPT.DepartmentGuid = PDT.DepartmentGuid
        WHERE PDT.PatientVisit = @PatientVisit 
          AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) > PDT.StartDateTime 
          AND (ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
        ORDER BY PDT.StartDateTime DESC
    ) amx
    OUTER APPLY (
        SELECT TOP 1 
            SOATValue, ISS2001Value, ISS2004Value,
            SOATSurgeryGrp, ISS2001SurgeryGrp, ISS2004SurgeryGrp,
            SOATArticle, ISS2001Article, ISS2004Article
        FROM ClinicalGeniusSupplyChain.dbo.ManualValues mvl WITH(NOLOCK)
        WHERE mvl.CUPSCode = pp.ProcedureCode -- FIXED: Bound directly to standard clinical procedure code
          AND mvl.YearOfService = YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) -- FIXED: Resolved broken pl alias references
    ) mvx
    WHERE pp.PatientVisit = @PatientVisit 
      AND pp.Active = 1
      AND pp.Facility = @FacilityId
),

-- ==========================================================================================
-- SECTION 12: Standalone Exception Priority Scoring
-- ==========================================================================================

AllMatchingProcedureExceptions AS (
    SELECT 
        opl.*,
        ce.PriceModifier AS ExceptionPriceModifier, -- FIXED: Exposed the raw column value to downstream components
        ce.ExceptionGuid,
        ROW_NUMBER() OVER (
            PARTITION BY opl.ProcedureGuid
            ORDER BY ce.Ranking DESC,
                     ABS(ce.PriceModifier) DESC, 
                     ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM OutpatientProcedureList opl
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = @ContractGuid 
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
        -- FIXED: Successfully maps the exposed variable name from the upstream partition
        ISNULL(ExceptionPriceModifier, 0.00) AS PriceModifier 
    FROM AllMatchingProcedureExceptions
    WHERE ExceptionPriorityRank = 1 
),

-- ==========================================================================================
-- SECTION 13: Standalone Outpatient Unit Resolution & Rate Binding
-- ==========================================================================================

OutpatientBaseUnits AS (
    SELECT 
        pe.ProcedureGuid, pe.ProcedureCode, pe.ProcedureDescription, pe.LaterialityCode, pe.ServiceGroup, 
        pe.TargetDate, pe.YearOfService, pe.RowShiftType, pe.ExceptionGuid, pe.CatalogValue, pe.PriceModifier, pe.Ambity,
        CAST(1 + (@AdjustmentPct / 100.00) + (pe.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        CAST(pe.CatalogValue AS DECIMAL(18,2)) AS RawCatalogUnits
    FROM OutpatientAppliedExceptions pe 
),

OutpatientFinalShiftAdjustments AS (
    SELECT 
        b.*,
        CAST(CASE WHEN b.RowShiftType IN (3, 4) THEN 1.25 ELSE 1.00 END AS DECIMAL(10,4)) AS ShiftMultiplier,
        CASE 
            WHEN @Manual = 'SOAT' AND b.TargetDate < '2024-01-01' THEN 'SMDLV'
            WHEN @Manual = 'SOAT' AND b.TargetDate >= '2024-01-01' THEN 'UVB'
            WHEN @Manual LIKE 'ISS%' THEN 'UVR' -- FIXED: Swapped text literal to wildcard to recognize ISS_2001/ISS_2004
            ELSE 'COP' 
        END AS ValueBasis,
        CAST(
            CASE 
                -- Historical SOAT (Pre-2024 SMDLV baseline parameters)
                WHEN @Manual = 'SOAT' AND b.TargetDate < '2024-01-01' THEN 
                    CASE YEAR(b.TargetDate)
                        WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 
                    END
                -- Modern SOAT (2024+ Ministry of Health UVB conversion allocations)
                WHEN @Manual = 'SOAT' AND b.TargetDate >= '2024-01-01' THEN 
                    CASE b.YearOfService 
                        WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 ELSE 12110.00 
                    END
                -- Unified ISS Contracts (Points mapped to corresponding contract year values)
                WHEN @Manual LIKE 'ISS%' THEN -- FIXED: Enforced wildcard coverage for multi-year ISS frameworks
                    CASE b.YearOfService 
                        WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 57540.00 
                    END
                ELSE 1.00 
            END AS DECIMAL(18,2)
        ) AS UnitMonetaryValue
    FROM OutpatientBaseUnits b
),

CalculatedOutpatientLines AS (
    SELECT 
        o.*,
        CAST(o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue * o.UnitMonetaryValue AS DECIMAL(18,2)) AS OutpatientLineTotal
    FROM OutpatientFinalShiftAdjustments o
)


-- ==========================================================================================
-- SECTION 14: Batch Standalone Procedure Ledger Insertion
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
    'Procedure' AS TransactionType,      -- Explicitly categorized as a standalone outpatient procedure
    @ClaimGuid, 
    NULL AS SurgeryGuid,                -- Omitted for standalone/non-surgical lines
    @ContractGuid, 
    f.ExceptionGuid, 
    ISNULL(f.Ambity, '02') AS Ambity,    -- Dynamic spatial timeline tracking integration
    f.UnitMonetaryValue, 
    f.ProcedureDescription, 
    NULL AS SurgicalGroup,               
    NULL AS SurgicalApproach,            
    0 AS SameApproach,                   
    f.RowShiftType AS ShiftTypeApplied,  
    0.00 AS SurchargeAmount,             
    f.ProcedureCode, 
    NULL AS CUMCode,                     
    f.TargetDate, 
    GETDATE() AS DateTimeEntered,        
    @Manual AS RevenueCode,              
    1 AS Quantity,                       
    1 AS ItemCost,                       -- Defaults to 1 for non-sequential standalone items
    f.LaterialityCode AS ItemSnomedCode, 
    f.RawCatalogUnits AS ItemAlternateCode, 
    f.BaseCalculatedValue AS LocalAmount, -- Captures the true applied exception price scale factor
    1.00 AS USDBasePrice,                -- Degradation factor defaults to 1.00 face value
    f.ShiftMultiplier AS USDPerItemChargeAmount, 
    f.ValueBasis AS PaymentType,
    f.OutpatientLineTotal AS NetAmount,  
    0.00 AS TaxAmount, 
    0.00 AS DiscountAmount, 
    f.OutpatientLineTotal AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM CalculatedOutpatientLines f;

SELECT @@ROWCOUNT AS StandaloneProceduresPosted;
GO

-- ==========================================================================================
-- SECTION 15: Set-Based Medication Matrix Flattening & Exception Prioritization
-- ==========================================================================================
-- 15a. COMPLIANCE REGISTRY: Official Colombian Legal Holidays (Projected 2024 - 2030)

;WITH ColombianHolidays AS (
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

-- 15b. Extract completed medication administration records and bind master formulary fields
ActiveMedicationList AS (
    SELECT 
        mar.PatientId, mar.PatientVisit, mar.MedicationCode, mar.MedicationName, mar.ActualDoseGiven, mar.QuantityUnit, mar.Facility,
        ISNULL(amx.Ambity, '01') AS Ambity, 
        ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) AS TargetDate,
        YEAR(ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) AS YearOfService,
        CAST(ISNULL(df.BasePrice, 0.00) AS DECIMAL(18,2)) AS FormularyBasePrice,
        CAST(ISNULL(df.Cost, 0.00) AS DECIMAL(18,2)) AS FormularyUnitCost,
        
        -- CRITICAL COMPLIANCE FIX: Detect if medication administration occurred inside an active absorbed bundle
        CAST(
            CASE 
                WHEN s.IsBundle = 1 AND s.MedicationIncluded = 1 THEN 1 
                ELSE 0 
            END AS BIT
        ) AS IsBundledInPackage,
        s.SurgeryGuid, -- Anchors tracking correlation
        
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN DATEPART(weekday, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) IN (6, 7) THEN 4 
            WHEN DATEPART(hour, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) < 7 THEN 3 
            WHEN DATEPART(hour, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType
    FROM ClinicalGeniusEhr.dbo.MedicationAdministrationRecords mar WITH(NOLOCK)
    INNER JOIN ClinicalGeniusSupplyChain.dbo.DrugFormulary df WITH(NOLOCK) ON df.MedicationCode = mar.MedicationCode
    LEFT JOIN ColombianHolidays h ON h.HolidayDate = CAST(ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) AS DATE)
    
    -- Evaluates spatial context safely against normalized target date parameters
    OUTER APPLY (
        SELECT TOP 1 DPT.Ambity 
        FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
        INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) ON DPT.DepartmentGuid = PDT.DepartmentGuid
        WHERE PDT.PatientVisit = @PatientVisit 
          AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) > PDT.StartDateTime 
          AND (ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
        ORDER BY PDT.StartDateTime DESC 
    ) amx
    
    -- Scans for concurrent surgical timelines on the same patient visit
    LEFT JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
        ON s.PatientVisit = mar.PatientVisit
        AND s.Status = 'Completed'
        -- Checks if the drug was administered within the operating window (plus a standard 4-hour recovery margin)
        AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) >= s.DateTimePerformed
        AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) <= DATEADD(HOUR, 4, s.DateTimePerformed)
        
    WHERE mar.PatientVisit = @PatientVisit
      AND mar.Status = 'Completed'
      AND mar.Facility = @FacilityId
      AND mar.ActualDoseGiven > 0
),

-- 15c. Score and rank contract exceptions dynamically row-by-row for medications
AllMatchingMedicationExceptions AS (
    SELECT 
        m.*,
        ISNULL(ce.PriceModifier, 0.00) AS PriceModifier, ce.ExceptionGuid,
        ROW_NUMBER() OVER (
            PARTITION BY m.PatientVisit, m.MedicationCode, m.TargetDate
            ORDER BY ce.Ranking DESC,
                     ABS(ce.PriceModifier) DESC, 
                     ce.ExceptionGuid ASC 
        ) AS ExceptionPriorityRank
    FROM ActiveMedicationList m
    LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
        ON ce.ContractGuid = @ContractGuid 
        AND ce.Active = 1 
        AND CAST(m.TargetDate AS DATE) >= ce.StartDate 
        AND CAST(m.TargetDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        AND ce.CUMSCode = m.MedicationCode 
        AND (ce.ShiftType = 1 OR ce.ShiftType = m.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = m.Ambity) 
),

-- 15d. Isolate highest scoring contract exception match and build calculation totals
CalculatedMedicationLines AS (
    SELECT 
        e.*,
        CAST(1 + (@AdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        
        -- RESOLUCIÓN 948 DE 2026 COMPLIANCE: If the medication is absorbed by a surgical package, force final charge to 0.00
        CAST(
            CASE 
                WHEN e.IsBundledInPackage = 1 THEN 0.00
                ELSE (e.ActualDoseGiven * e.FormularyBasePrice) * CAST(1 + (@AdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4))
            END AS DECIMAL(18,2)
        ) AS MedicationLineTotal
    FROM AllMatchingMedicationExceptions e
    WHERE e.ExceptionPriorityRank = 1
)

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
    'Medication' AS TransactionType,       -- Explicitly isolates pharmaceutical care lines
    @ClaimGuid, 
    f.SurgeryGuid,                         -- FIXED: Preserves the surgical connection for zeroed bundle tracking lines
    @ContractGuid, 
    f.ExceptionGuid, 
    ISNULL(f.Ambity, '02') AS Ambity,             
    f.FormularyBasePrice AS BaseUnitValue, -- Base price pulled from formulary configuration
    f.MedicationName AS SurgicalComponent, -- Captures the clinical drug string description
    NULL AS SurgicalGroup,                               
    NULL AS SurgicalApproach,                               
    0 AS SameApproach,                                  
    f.RowShiftType AS ShiftTypeApplied,  
    0.00 AS SurchargeAmount,                               
    f.MedicationCode AS CupsCode,          -- Tracks MedicationCode for structural lookup alignment
    f.MedicationCode AS CUMCode,           -- Official CUM identifier for invoice tracking
    f.TargetDate AS ExternalProcessedDateTime, 
    GETDATE() AS DateTimeEntered,                          
    @Manual AS RevenueCode,                            
    f.ActualDoseGiven AS Quantity,         -- Quantity records the raw clinical dosage given
    f.FormularyUnitCost AS ItemCost,       -- Captures the internal acquisition cost baseline
    NULL AS ItemSnomedCode,                               
    f.QuantityUnit AS ItemAlternateCode,   -- Records units of measure (e.g., 'Mg', 'Vial')
    f.BaseCalculatedValue AS LocalAmount,  -- Applied contract/exception factor percentage
    1.00 AS USDBasePrice,                               
    1.00 AS USDPerItemChargeAmount,                               
    'COP' AS PaymentType,                              
    f.MedicationLineTotal AS NetAmount,    -- Drops to 0.00 natively if IsBundledInPackage = 1
    0.00 AS TaxAmount,                               
    0.00 AS DiscountAmount,                               
    f.MedicationLineTotal AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM CalculatedMedicationLines f;

SELECT @@ROWCOUNT AS MedicationLinesPosted;
GO
-- ==========================================================================================
-- SECTION 17: Set-Based Inpatient Stay (Estancias) Expansion and Calendar Splitting
-- ==========================================================================================
-- Maps bed-day intervals, recursively expanding multi-day blocks into single-day rows 
-- to safely calculate cross-fiscal-year baseline tariff changes.

WITH Tally(n) AS (
    SELECT TOP 365 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
    FROM sys.all_columns
),
ExpandedStayDays AS (
    SELECT 
        hos.StayGuid,
        hos.PatientVisit,
        hos.BedCategoryCode,   -- Maps to CUPS code for the target stay type
        hos.FacilityId,
        -- Generate a single calendar date for each night spent in the hospital bed
        CAST(DATEADD(DAY, t.n, hos.AdmissionDateTime) AS DATE) AS StayCalendarDate,
        -- Determine the corresponding year of service to bind correct historical baseline rates
        YEAR(DATEADD(DAY, t.n, hos.AdmissionDateTime)) AS YearOfService
    FROM ClinicalGeniusEhr.dbo.PatientHospitalStays hos WITH(NOLOCK)
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
        -- Resolve legacy manual values matching target category steps per active year
        CASE 
            WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
            WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Value
            ELSE mvx.ISS2004Value 
        END AS RoomCatalogUnits,
        CASE 
            WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
            WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Article
            ELSE mvx.ISS2004Article 
        END AS ArticleGroup,
        -- Check if room stays are pre-absorbed by a global contract package (e.g., Pago por Caso)
        CAST(
            CASE 
                -- If a separate surgical package explicitly absorbed stay rooms, trigger zero-pricing
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
        SELECT TOP 1 
            SOATValue, ISS2001Value, ISS2004Value,
            SOATArticle, ISS2001Article, ISS2004Article
        FROM ClinicalGeniusSupplyChain.dbo.ManualValues mvl WITH(NOLOCK)
        WHERE mvl.CUPSCode = es.BedCategoryCode
          AND mvl.YearOfService = es.YearOfService
    ) mvx
),

-- Score and rank targeted contract exceptions for individual bed types row-by-row
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
        ON ce.ContractGuid = @ContractGuid 
        AND ce.Active = 1 
        AND st.StayCalendarDate >= ce.StartDate 
        AND st.StayCalendarDate <= ISNULL(ce.EndDate, '9999-12-31') 
        -- Matches Article 25 (Internación) for standard manual schemas
        AND ce.ArticleGroup = st.ArticleGroup
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '03') -- Scopes inpatient care blocks
),

-- ==========================================================================================
-- SECTION 19: Mathematical Evaluation & Monetary Rate Integration
-- ==========================================================================================
CalculatedStayDays AS (
    SELECT 
        ex.*,
        CAST(1 + (@AdjustmentPct / 100.00) + (ex.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        CASE 
            WHEN @Manual = 'SOAT' AND ex.StayCalendarDate < '2024-01-01' THEN 'SMDLV'
            WHEN @Manual = 'SOAT' AND ex.StayCalendarDate >= '2024-01-01' THEN 'UVB'
            WHEN @Manual LIKE 'ISS%' THEN 'UVR' 
            ELSE 'COP' 
        END AS ValueBasis,
        CAST(
            CASE 
                -- Historical SOAT (Pre-2024 SMDLV baseline parameters)
                WHEN @Manual = 'SOAT' AND ex.StayCalendarDate < '2024-01-01' THEN 
                    CASE ex.YearOfService
                        WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 
                    END
                -- Modern SOAT indexed to the core statutory UVB increments
                WHEN @Manual = 'SOAT' AND ex.StayCalendarDate >= '2024-01-01' THEN 
                    CASE ex.YearOfService 
                        WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 ELSE 12110.00 
                    END
                -- ISS Points mapped per respective service year values
                WHEN @Manual LIKE 'ISS%' THEN 
                    CASE ex.YearOfService 
                        WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 57540.00 
                    END
                ELSE 1.00 
            END AS DECIMAL(18,2)
        ) AS UnitMonetaryValue
    FROM AllMatchingStayExceptions ex
    WHERE ex.ExceptionPriorityRank = 1
),
FinalStayLiquidationLines AS (
    SELECT 
        c.*,
        -- If room stay nights intersect a package that includes rooms, force NetAmount to exactly 0.00
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
    'Stay' AS TransactionType,         -- Isolated as hospital room care lines
    @ClaimGuid, 
    NULL AS SurgeryGuid, 
    @ContractGuid, 
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
    @Manual AS RevenueCode, 
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
-- Filters to completed panels, resolves geographic spatial context, and maps the parent CUPS code.

WITH CompletedLabPanels AS (
    SELECT 
        lto.OrderGuid,
        lto.CPTCode AS PanelCupsCode,      -- Maps your CPTCode column directly to the Colombian CUPS registry
        lto.CPTDescription AS PanelDescription,
        lto.PatientVisit,
        lto.Facility AS FacilityId,
        ISNULL(lto.PinDate, lto.DateTimeScheduled) AS CompletionDate, -- The legal point of execution for RIPS
        YEAR(ISNULL(lto.PinDate, lto.DateTimeScheduled)) AS YearOfService,
        ISNULL(amx.Ambity, '02') AS Ambity, -- Dynamic spatial department tracking fallback
        
        -- Determine shift types for weekend/night premium surcharges (if contract exceptions dictate it)
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN DATEPART(weekday, ISNULL(lto.PinDate, lto.DateTimeScheduled)) IN (6, 7) THEN 4 
            WHEN DATEPART(hour, ISNULL(lto.PinDate, lto.DateTimeScheduled)) < 7 THEN 3 
            WHEN DATEPART(hour, ISNULL(lto.PinDate, lto.DateTimeScheduled)) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType,

        -- SURGICAL BUNDLE INTERCEPT GATE: Detect if this lab occurred inside an active bundle that includes labs
        CAST(
            CASE 
                WHEN EXISTS (
                    SELECT 1 FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
                    WHERE s.PatientVisit = lto.PatientVisit
                      AND s.Status = 'Completed'
                      AND s.IsBundle = 1
                      -- Assumes an extended surgical table flag or rules absorption block. 
                      -- If material/procedure checks cover labs, substitute that toggle name here:
                      AND s.ProcedureIncluded = 1 
                      AND ISNULL(lto.PinDate, lto.DateTimeScheduled) >= s.DateTimePerformed
                      AND ISNULL(lto.PinDate, lto.DateTimeScheduled) <= DATEADD(HOUR, 6, s.DateTimePerformed)
                ) THEN 1 
                ELSE 0 
            END AS BIT
        ) AS IsLabAbsorbedByBundle
    FROM ClinicalGeniusEhr.dbo.PatientLabTestOrders lto WITH(NOLOCK)
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
      AND lto.Status = 'Completed'         -- STRICT GATE: Only liquidates executed, resulted care profiles
      AND lto.Facility = @FacilityId        -- Multi-tenant isolation guard
      AND ISNULL(lto.ExistingCharge, 0) = 0 -- Defensive wall against duplicate pipeline runs
),

-- ==========================================================================================
-- SECTION 22: Annual Rate Binding & Contract Exception Priority Matrix
-- ==========================================================================================
LabLinesWithTariffs AS (
    SELECT 
        cl.*,
        -- Set the core relative points or cash values matching the year the lab was completed
        CASE 
            WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
            WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Value
            ELSE mvx.ISS2004Value 
        END AS CatalogValue,
        CASE 
            WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
            WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Article
            ELSE mvx.ISS2004Article 
        END AS ArticleGroup,
        CASE 
            WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
            WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
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
        ON ce.ContractGuid = @ContractGuid 
        AND ce.Active = 1 
        AND CAST(lt.CompletionDate AS DATE) >= ce.StartDate 
        AND CAST(lt.CompletionDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        -- Target Article 17 (Laboratorio Clínico y Patología) for ISS or corresponding SOAT blocks
        AND ce.ArticleGroup = lt.ArticleGroup
        AND (ce.ShiftType = 1 OR ce.ShiftType = lt.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = lt.Ambity)
),
CalculatedLabLines AS (
    SELECT 
        e.*,
        CAST(1 + (@AdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        CASE 
            WHEN @Manual = 'SOAT' AND e.CompletionDate < '2024-01-01' THEN 'SMDLV'
            WHEN @Manual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 'UVB'
            WHEN @Manual LIKE 'ISS%' THEN 'UVR' 
            ELSE 'COP' 
        END AS ValueBasis,
        CAST(
            CASE 
                WHEN @Manual = 'SOAT' AND e.CompletionDate < '2024-01-01' THEN 
                    CASE e.YearOfService WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 END
                WHEN @Manual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 
                    CASE e.YearOfService WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 ELSE 12110.00 END
                WHEN @Manual LIKE 'ISS%' THEN 
                    CASE e.YearOfService WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 57540.00 END
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
                -- RESOLUCIÓN 948 DE 2026: If the panel is pre-absorbed inside an operating block, force output charge to 0.00
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
    'Procedure' AS TransactionType,     -- Labs map cleanly as high-volume diagnostic procedures
    @ClaimGuid, 
    NULL AS SurgeryGuid, 
    @ContractGuid, 
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
    @Manual AS RevenueCode, 
    1 AS Quantity, 
    0.00 AS ItemCost, 
    f.OrderGuid AS ItemSnomedCode,     -- Preserves parent order GUID tracing for transactional auditing
    NULL AS ItemAlternateCode, 
    f.BaseCalculatedValue AS LocalAmount, 
    1.00 AS USDBasePrice, 
    1.00 AS USDPerItemChargeAmount, 
    f.ValueBasis AS PaymentType, 
    f.PanelLineNetAmount AS NetAmount,  -- Automatically drops to 0.00 COP if absorbed by bundle
    0.00 AS TaxAmount, 
    0.00 AS DiscountAmount, 
    f.PanelLineNetAmount AS PerItemChargeAmount, 
    'Active' AS [Status]
FROM FinalLabLiquidation f;

SELECT @@ROWCOUNT AS LabPanelsPosted;

-- ==========================================================================================
-- SECTION 24: Set-Based Diagnostic Imaging Flattening and Base Matching (Catalog Aligned)
-- ==========================================================================================
-- Joins your master list table to pull the verified CPTCode (CUPS mapping) for completed items.

WITH CompletedImagingOrders AS (
    SELECT 
        img.ImagingOrderGuid,
        ioi.CPTCode AS ImagingCupsCode,       -- FIXED: Now inherits the correct CPTCode from your catalog table
        img.ImagingOrderDescription AS ImagingDescription,
        img.PatientVisit,
        img.Facility AS FacilityId,
        ISNULL(img.DateTimeUpdated, img.DateTimeEntered) AS CompletionDate, -- Timestamp for RIPS timeline
        YEAR(ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) AS YearOfService,
        ISNULL(amx.Ambity, '02') AS Ambity,    -- Timeline spatial department tracking fallback
        
        -- Determine shift types for weekend/night premium surcharges
        CASE 
            WHEN h.HolidayDate IS NOT NULL THEN 4
            WHEN DATEPART(weekday, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) IN (6, 7) THEN 4 
            WHEN DATEPART(hour, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) < 7 THEN 3 
            WHEN DATEPART(hour, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) > 18 THEN 3
            ELSE 2 
        END AS RowShiftType,

        -- SURGICAL BUNDLE INTERCEPT GATE: Detect if this imaging occurred inside an active bundle that absorbs labs/imaging
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
    -- NEW: Master link tracking join to fetch the billing CPT code natively from the facility procedural definitions
    INNER JOIN ClinicalGeniusEhr.dbo.ImagingOrderItems ioi WITH(NOLOCK)
        ON ioi.ImageOrderItemGuid = img.ImageOrderItemGuid
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
      AND img.OrderStatus = 'Completed'     -- STRICT GATE: Only liquidates completed diagnostic imaging procedures
      AND img.Facility = @FacilityId         -- Multi-tenant isolation guard
),

-- ==========================================================================================
-- SECTION 25: Annual Rate Binding & Contract Exception Priority Matrix (Imaging)
-- ==========================================================================================
ImagingLinesWithTariffs AS (
    SELECT 
        io.*,
        -- Set the core relative points or cash values matching the year the imaging was completed
        CASE 
            WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
            WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Value
            ELSE mvx.ISS2004Value 
        END AS CatalogValue,
        CASE 
            WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
            WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Article
            ELSE mvx.ISS2004Article 
        END AS ArticleGroup,
        CASE 
            WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
            WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
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
        ON ce.ContractGuid = @ContractGuid 
        AND ce.Active = 1 
        AND CAST(im.CompletionDate AS DATE) >= ce.StartDate 
        AND CAST(im.CompletionDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
        -- Target Article 15 (Procedimientos de Imagenología)
        AND ce.ArticleGroup = im.ArticleGroup
        AND (ce.ShiftType = 1 OR ce.ShiftType = im.RowShiftType) 
        AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = im.Ambity)
),
CalculatedImagingLines AS (
    SELECT 
        e.*,
        CAST(1 + (@AdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
        CASE 
            WHEN @Manual = 'SOAT' AND e.CompletionDate < '2024-01-01' THEN 'SMDLV'
            WHEN @Manual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 'UVB'
            WHEN @Manual LIKE 'ISS%' THEN 'UVR' 
            ELSE 'COP' 
        END AS ValueBasis,
        CAST(
            CASE 
                WHEN @Manual = 'SOAT' AND e.CompletionDate < '2024-01-01' THEN 
                    CASE e.YearOfService WHEN 2021 THEN 30333.33 WHEN 2022 THEN 33333.33 WHEN 2023 THEN 38666.66 ELSE 38666.66 END
                WHEN @Manual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 
                    CASE e.YearOfService WHEN 2024 THEN 10950.00 WHEN 2025 THEN 11550.00 WHEN 2026 THEN 12110.00 WHEN 2027 THEN 12110.00 ELSE 12110.00 END
                WHEN @Manual LIKE 'ISS%' THEN 
                    CASE e.YearOfService WHEN 2024 THEN 43333.33 WHEN 2025 THEN 46666.66 WHEN 2026 THEN 57540.00 WHEN 2027 THEN 57540.00 ELSE 57540.00 END
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
                -- RESOLUCIÓN 948 DE 2026: Drop output price to 0.00 if pre-absorbed by an active surgical bundle
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
    @ClaimGuid, 
    NULL AS SurgeryGuid, 
    @ContractGuid, 
    f.ExceptionGuid, 
    f.Ambity, 
    f.UnitMonetaryValue, 
    'Procedimiento de Imagenología: ' + f.ImagingDescription, 
    NULL AS SurgicalGroup, 
    NULL AS SurgicalApproach, 
    0 AS SameApproach, 
    f.RowShiftType AS ShiftTypeApplied, 
    0.00 AS SurchargeAmount, 
    f.ImagingCupsCode AS CupsCode,       -- Successfully holds the facility verified CPT/CUPS catalog code
    NULL AS CUMCode, 
    f.CompletionDate, 
    GETDATE() AS DateTimeEntered, 
    @Manual AS RevenueCode, 
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
GO

-- ==========================================================================================
-- SECTION 27: Embedded Inline Statutory Co-Payment Capping Registry (Topes de Copagos)
-- ==========================================================================================
-- Initialize parameters for cap validation checks
DECLARE @PatientFinancialClass VARCHAR(5) = 'A',
        @MaxAllowedCopayPerEvent DECIMAL(18,2) = 99999999.99,
        @CurrentCalculatedVisitCopay DECIMAL(18,2) = 0.00;

-- 1. Extract the patient's current FinancialClass bracket from the master profile
SELECT TOP 1 
    @PatientFinancialClass = pat.FinancialClass
FROM ClinicalGeniusEhr.dbo.PatientTable pat WITH(NOLOCK)
WHERE pat.PatientId = @PatientId;

-- 2. Bind the exact maximum legal cap limit for this year of service
-- Leverages a simple conditional lookup instead of an independent CTE for fast batch variable setting
SET @MaxAllowedCopayPerEvent = CASE YEAR(GETDATE())
    -- 2026 Statutory Limits
    WHEN 2026 THEN 
        CASE @PatientFinancialClass
            WHEN 'A'  THEN 351210.00
            WHEN 'B'  THEN 1406670.00
            WHEN 'C'  THEN 2813340.00
            WHEN 'S1' THEN 0.00
            WHEN 'S2' THEN 110450.00
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

-- 3. Calculate what your PayerClaims currently registers for patient liability
SELECT TOP 1
    @CurrentCalculatedVisitCopay = ISNULL(pyc.Copay, 0.00) + ISNULL(pyc.MedicalCoinsurance, 0.00)
FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
WHERE pyc.ClaimGuid = @ClaimGuid
  AND pyc.FacilityId = @FacilityId;


-- ==========================================================================================
-- SECTION 28: Co-Payment Cap Correction Rule & Balance Shifting
-- ==========================================================================================
IF @CurrentCalculatedVisitCopay > @MaxAllowedCopayPerEvent
BEGIN
    -- If the patient has crossed the statutory cap threshold:
    -- 1. Force the client-facing liability to exactly the legal maximum limit allowed.
    -- 2. Under Decreto 1652, shift the excess balance onto the Payer's coverage calculation so the hospital gets paid.
    
    UPDATE pyc
    SET pyc.Copay = CASE WHEN @PatientFinancialClass = 'S1' THEN 0.00 ELSE @MaxAllowedCopayPerEvent END,
        pyc.MedicalCoinsurance = 0.00, -- Erase the excess variable coinsurance lines
        -- Shift the remaining unpaid balance onto the Payer's coverage calculation so the hospital gets paid
        pyc.PayerCoverageAmount = pyc.PayerCoverageAmount + (@CurrentCalculatedVisitCopay - @MaxAllowedCopayPerEvent),
        pyc.LastUpdatedBy = 'CopayCappingMatrix'
    FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc
    WHERE pyc.ClaimGuid = @ClaimGuid
      AND pyc.FacilityId = @FacilityId;
      
    SELECT 'CO-PAYMENT CAPPED: Excess shifted to insurer' AS AuditStatus;
END
ELSE
BEGIN
    SELECT 'CO-PAYMENT WITHIN LEGAL LIMITS: No shift required' AS AuditStatus;
END;
GO
