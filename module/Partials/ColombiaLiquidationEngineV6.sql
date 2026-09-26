-- ==========================================================================================
-- CLINICAL GENIUS LIQUIDATION ENGINE - SURGERY ISOLATED ARCHITECTURE (VERSION 5.1 COMPREHENSIVE)
-- TARGET ARCHITECTURE: SQL Server Enterprise 2014+ NATIVE
-- STATUTORY ALIGNMENT & ARCHITECTURAL HIGHLIGHTS:
--   1. Full transaction atomicity: BEGIN TRY ... BEGIN TRANSACTION ... COMMIT / ROLLBACK.
--   2. Preserved normalized multi-procedure / multi-surgeon model:
--        - ScheduledSurgeryProcedures (Child procedures, IncisionNumber, Surgical Staff)
--        - ScheduledSurgeryCharges (Direct procedure-linked high-cost supplies/implants)
--   3. Poly-Trauma Multiple Surgery Degradation (Decreto 2423/96 Arts. 71-74 & ISS Acuerdos 256/312):
--        - Professional fees ranked/degraded per SurgeonId (independent specialty 100% entitlement)
--        - Facility fees (Sala/Materiales) ranked/degraded strictly per IncisionNumber
--   4. Colombian Off-Hours Surcharge Compliance:
--        - Restricts 25% surcharge to Sundays (DATENAME = 'Sunday') and official statutory holidays
--        - Excludes surgical assistants (Subtypes 3 & 6) and facility rights from off-hours premiums
--   5. Restored Complete Diagnostic Pipeline:
--        - Section 6a: Outpatient Procedures
--        - Section 6b: Inpatient Hospital Stay Days (Estancias)
--        - Section 6c: Medication Administration Records & Surgical Bundle Absorption
--        - Section 6d: Laboratory & Pathology Diagnostic Panels
--        - Section 6e: Diagnostic Imaging Orders (CPT/CUPS Master Linked)
--   6. Dynamic statutory rate binding via UnitParameters & StatutoryCopayLimits
-- ==========================================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;

-- ==========================================================================================
-- SECTION 1: Visit-Wide Contract Context & Variable Extraction
-- ==========================================================================================
DECLARE @PatientVisit NVARCHAR(50), 
        @FacilityId   NVARCHAR(50), 
        @PatientId    NVARCHAR(50);

-- Runtime Execution Parameters
DECLARE @ContractGuid NVARCHAR(50) = NULL, 
        @Manual       VARCHAR(20)  = NULL,          
        @AdjustmentPct DECIMAL(5,2) = NULL,  
        @ClaimGuid     NVARCHAR(50) = NULL;

-- 1a. Extract active, pending primary contract variables and patient context
SELECT TOP 1 
    @ClaimGuid     = pyc.ClaimGuid,
    @PatientId     = pyc.PatientId,
    @ContractGuid  = ppy.ContractGuid,
    @Manual        = isc.EntityCode,
    @AdjustmentPct = isc.AdjustmentPct
FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
    ON ppy.PatientPayerGuid = pyc.PayerGuid
INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
    ON isc.ContractGuid = ppy.ContractGuid
WHERE pyc.PatientVisit = @PatientVisit
  AND pyc.Status = 'Pending'
  AND pyc.FacilityId = @FacilityId
ORDER BY pyc.BatchNumber ASC; 

-- 1b. Safety Gate: Route to validated Self-Pay / SOAT fallback baseline
IF @ContractGuid IS NULL OR @Manual IS NULL
BEGIN
    SET @Manual = 'SOAT';
    SET @AdjustmentPct = 0.00;
END;

-- ==========================================================================================
-- SECTION 2: Compliance Pre-Loading & Global Temp Structures
-- ==========================================================================================
IF OBJECT_ID('tempdb..#ColombianHolidays') IS NOT NULL DROP TABLE #ColombianHolidays;
CREATE TABLE #ColombianHolidays (
    HolidayDate DATE PRIMARY KEY CLUSTERED
);

INSERT INTO #ColombianHolidays (HolidayDate)
VALUES
    ('2024-01-01'),('2024-01-08'),('2024-03-25'),('2024-03-28'),('2024-03-29'),('2024-05-01'),('2024-05-13'),('2024-06-03'),
    ('2024-06-10'),('2024-07-01'),('2024-07-20'),('2024-08-07'),('2024-08-19'),('2024-10-14'),('2024-11-04'),('2024-11-11'),
    ('2024-12-08'),('2024-12-25'),
    ('2025-01-01'),('2025-01-13'),('2025-03-24'),('2025-04-17'),('2025-04-18'),('2025-05-01'),('2025-06-02'),('2025-06-23'),
    ('2025-06-30'),('2025-07-20'),('2025-08-07'),('2025-08-18'),('2025-10-13'),('2025-11-03'),('2025-11-16'),('2025-12-08'),
    ('2025-12-25'),
    ('2026-01-01'),('2026-01-12'),('2026-03-23'),('2026-04-02'),('2026-04-03'),('2026-05-01'),('2026-05-18'),('2026-06-08'),
    ('2026-06-15'),('2026-06-29'),('2026-07-20'),('2026-08-07'),('2026-08-17'),('2026-10-12'),('2026-11-02'),('2026-11-16'),
    ('2026-12-08'),('2026-12-25'),
    ('2027-01-01'),('2027-01-11'),('2027-03-22'),('2027-03-25'),('2027-03-26'),('2027-05-01'),('2027-05-10'),('2027-05-31'),
    ('2027-06-07'),('2027-07-05'),('2027-07-12'),('2027-07-20'),('2027-08-07'),('2027-08-16'),('2027-10-18'),('2027-11-01'),
    ('2027-11-15'),('2027-12-08'),('2027-12-25'),
    ('2028-01-01'),('2028-01-10'),('2028-03-20'),('2028-04-13'),('2028-04-14'),('2028-05-01'),('2028-05-29'),('2028-06-19'),
    ('2028-06-26'),('2028-07-10'),('2028-07-20'),('2028-08-07'),('2028-08-21'),('2028-10-16'),('2028-11-06'),('2028-11-13'),
    ('2028-12-08'),('2028-12-25'),
    ('2029-01-01'),('2029-01-08'),('2029-03-19'),('2029-03-29'),('2029-03-30'),('2029-05-01'),('2029-06-04'),('2029-06-11'),
    ('2029-07-02'),('2029-07-20'),('2029-08-07'),('2029-08-20'),('2029-10-15'),('2029-11-05'),('2029-11-12'),('2029-12-08'),
    ('2029-12-25'),
    ('2030-01-01'),('2030-01-07'),('2030-03-25'),('2030-04-18'),('2030-04-19'),('2030-05-01'),('2030-06-03'),('2030-06-24'),
    ('2030-07-01'),('2030-07-08'),('2030-07-20'),('2030-08-07'),('2030-08-19'),('2030-10-14'),('2030-11-04'),('2030-11-11'),
    ('2030-12-08'),('2030-12-25');

-- Atomic Execution Shell
BEGIN TRY
    BEGIN TRANSACTION;

    -- ==========================================================================================
    -- SECTION 3: Targeted Pre-Invoice Staging Clearance
    -- ==========================================================================================
    UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK) 
    SET Status = 'Canceled',
        DateTimeLastUpdated = GETDATE(),            
        LastUpdatedBy = 'PricingEngine'            
    WHERE PatientVisit = @PatientVisit 
      AND TransactionType IN (
            'Surgery', 'Procedure', 'Medication', 'Stay', 
            'RoomRights', 'Supplies', 'Honorary', 'BundleMaster'
      )
      AND Status <> 'Canceled'                      
      AND Facility = @FacilityId                    
      AND (ElectronicInvoiceStatus IS NULL OR ElectronicInvoiceStatus <> 'Transmitted');

    -- ==========================================================================================
    -- SECTION 4: Normalized Multi-Surgery Pipeline Matrix Execution
    -- ==========================================================================================
    ;WITH MasterSoatGroupsArray AS (
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
    MasterIssFacilityArray AS (
        SELECT IssSurgicalGroup, SubtypeCode, CAST(FacilityUvrPoints AS DECIMAL(18,2)) AS FacilityUvrPoints
        FROM (VALUES
              (20, 4, 55.00),  (20, 5, 40.00) 
            , (21, 4, 70.00),  (21, 5, 55.00) 
            , (22, 4, 105.00), (22, 5, 80.00) 
            , (23, 4, 145.00), (23, 5, 115.00)
        ) IssArrayRows(IssSurgicalGroup, SubtypeCode, FacilityUvrPoints)
    ),
    RawProcedureEntries AS (
        SELECT 
            s.SurgeryGuid,
            sp.SurgeryProcedureGuid,
            s.DateTimePerformed,
            s.Laterality,
            s.SurgeryApproach,
            sp.SurgeonId,
            sp.AnesthesiologistId AS Anesthesiologist,
            sp.AssistantId1       AS SurgeonId2,
            sp.AssistantId2       AS SurgeonId3,
            ISNULL(sp.IncisionNumber, 1) AS IncisionNumber,
            sp.IsPrimary AS IsClinicalPrimary,
            YEAR(s.DateTimePerformed) AS YearOfService,
            sp.ProcedureGuid,
            CAST(ISNULL(s.IsBundle, 0) AS BIT) AS IsBundle,
            s.PrimaryProcedure AS BundleCupsCode,
            s.BundleDescription,
            CAST(ISNULL(s.BundlePrice, 0.00) AS DECIMAL(18,2)) AS BundlePrice,
            CAST(ISNULL(s.SurgeonIncluded, 0) AS BIT) AS SurgeonIncluded,
            CAST(ISNULL(s.AnesthesiologistIncluded, 0) AS BIT) AS AnesthesiologistIncluded,
            CAST(ISNULL(s.AssistantIncluded, 0) AS BIT) AS AssistantIncluded,
            CAST(ISNULL(s.RoomIncluded, 0) AS BIT) AS RoomIncluded,
            CAST(ISNULL(s.MaterialIncluded, 0) AS BIT) AS MaterialIncluded,
            CAST(ISNULL(s.MedicationIncluded, 0) AS BIT) AS MedicationIncluded,
            CASE 
                WHEN h.HolidayDate IS NOT NULL THEN 4
                WHEN DATENAME(weekday, s.DateTimePerformed) = 'Sunday' THEN 4 
                WHEN DATEPART(hour, s.DateTimePerformed) < 7 THEN 3 
                WHEN DATEPART(hour, s.DateTimePerformed) > 18 THEN 3
                ELSE 2 
            END AS RowShiftType
        FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeryProcedures sp WITH(NOLOCK)
            ON sp.SurgeryGuid = s.SurgeryGuid AND sp.Active = 1
        LEFT JOIN #ColombianHolidays h ON h.HolidayDate = CAST(s.DateTimePerformed AS DATE)
        WHERE s.PatientVisit = @PatientVisit 
          AND s.Status = 'Completed'
          AND s.Facility = @FacilityId
    ),
    ProceduresWithCodes AS (
        SELECT 
            rp.*,
            CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
                 WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Value
                 ELSE mvx.ISS2004Value END AS ManualValue,
            CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
                 WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
                 ELSE mvx.ISS2004SurgeryGrp END AS SurgeryGroup,
            CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
                 WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Article
                 ELSE mvx.ISS2004Article END AS ArticleGroup,
            pai.RVSCode AS CUPSCode
        FROM RawProcedureEntries rp
        INNER JOIN ClinicalGeniusEhr.dbo.ProcedureAdministrationItems pai WITH(NOLOCK) 
            ON rp.ProcedureGuid = pai.ProcedureGuid 
        OUTER APPLY (
            SELECT TOP 1 
                SOATValue, ISS2001Value, ISS2004Value,
                SOATSurgeryGrp, ISS2001SurgeryGrp, ISS2004SurgeryGrp,
                SOATArticle, ISS2001Article, ISS2004Article
            FROM ClinicalGeniusSupplyChain.dbo.ManualValues mvl WITH(NOLOCK)
            WHERE mvl.CUPSCode = pai.RVSCode
              AND mvl.YearOfService = rp.YearOfService
        ) mvx
    ),
    IncisionValuation AS (
        SELECT 
            pw.*,
            ROW_NUMBER() OVER (
                PARTITION BY pw.SurgeryGuid, pw.IncisionNumber
                ORDER BY 
                    CASE WHEN @Manual = 'SOAT' THEN pw.SurgeryGroup ELSE 0 END DESC,
                    ISNULL(pw.ManualValue, 0.00) DESC,
                    pw.SurgeryProcedureGuid ASC
            ) AS RankWithinIncision,
            MAX(ISNULL(pw.ManualValue, 0.00)) OVER (
                PARTITION BY pw.SurgeryGuid, pw.IncisionNumber
            ) AS MaxIncisionValue
        FROM ProceduresWithCodes pw
    ),
    IncisionHierarchy AS (
        SELECT 
            iv.*,
            DENSE_RANK() OVER (
                PARTITION BY iv.SurgeryGuid
                ORDER BY iv.MaxIncisionValue DESC, iv.IncisionNumber ASC
            ) AS IncisionSessionRank
        FROM IncisionValuation iv
    ),
    SpecialistHierarchy AS (
        SELECT 
            ih.*,
            ROW_NUMBER() OVER (
                PARTITION BY ih.SurgeryGuid, ih.SurgeonId
                ORDER BY 
                    CASE WHEN @Manual = 'SOAT' THEN ih.SurgeryGroup ELSE 0 END DESC,
                    ISNULL(ih.ManualValue, 0.00) DESC,
                    ih.SurgeryProcedureGuid ASC
            ) AS SpecialistProcedureRank
        FROM IncisionHierarchy ih
    ),
    AllMatchingExceptions AS (
        SELECT 
            p.*, 
            ISNULL(ce.PriceModifier, 0.00) AS PriceModifier, 
            ce.ExceptionGuid,
            ROW_NUMBER() OVER (
                PARTITION BY p.SurgeryProcedureGuid
                ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.ExceptionGuid ASC 
            ) AS ExceptionPriorityRank
        FROM SpecialistHierarchy p
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
    FinalLineItemPricing AS (
        SELECT 
            pe.*, 
            v.SubtypeCode, 
            v.SubtypeName,
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
            CAST(1 + (@AdjustmentPct / 100.00) + (ISNULL(pe.PriceModifier, 0.00) / 100.00) AS DECIMAL(10,4)) AS AppliedExceptionFactor
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
        SELECT rm.*
        FROM FinalLineItemPricing rm
        WHERE (rm.SubtypeCode = 2 AND rm.Anesthesiologist IS NOT NULL)
           OR (rm.SubtypeCode = 3 AND rm.SurgeonId2 IS NOT NULL)
           OR (rm.SubtypeCode = 6 AND rm.SurgeonId3 IS NOT NULL)
           OR rm.SubtypeCode IN (1, 4, 5)
    ),
    CatalogBaseUnits AS (
        SELECT 
            f.*,
            CAST(
                CASE 
                    WHEN @Manual = 'SOAT' AND f.SubtypeCode = 3 AND f.SurgeryGroup <= 5 THEN 0.00
                    WHEN @Manual = 'SOAT' AND f.SubtypeCode = 6 AND f.SurgeryGroup <= 10 THEN 0.00
                    WHEN @Manual = 'SOAT' THEN ISNULL(soat.BaseUnits, 0.00)
                    WHEN @Manual LIKE 'ISS%' AND f.SubtypeCode IN (1, 2, 3, 6) THEN ISNULL(f.ManualValue, 0.00)
                    WHEN @Manual LIKE 'ISS%' AND f.SubtypeCode IN (4, 5) THEN ISNULL(iss.FacilityUvrPoints, 0.00)
                    ELSE 0.00 
                END AS DECIMAL(18,2)
            ) AS RawCatalogUnits
        FROM RemoveMissingStaff f 
        LEFT JOIN MasterSoatGroupsArray soat 
            ON @Manual = 'SOAT' 
            AND soat.SurgicalGroup = f.SurgeryGroup 
            AND soat.SubtypeCode = CASE WHEN f.SubtypeCode = 6 THEN 3 ELSE f.SubtypeCode END
        LEFT JOIN MasterIssFacilityArray iss 
            ON @Manual LIKE 'ISS%'
            AND f.SubtypeCode IN (4, 5)
            AND iss.IssSurgicalGroup = f.SurgeryGroup
            AND iss.SubtypeCode = f.SubtypeCode
    ),
    SurgicalDegradationRules AS (
        SELECT 
            r.*,
            CAST(
                CASE 
                    -- Professional Fees: Partitioned by Specialist & Clinical Incision
                    WHEN r.SubtypeCode IN (1, 2, 3, 6) THEN
                        CASE 
                            WHEN r.SpecialistProcedureRank = 1 THEN 
                                CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END
                            
                            WHEN r.SpecialistProcedureRank > 1 AND r.RankWithinIncision > 1 THEN
                                CASE 
                                    WHEN @Manual = 'SOAT' THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                    WHEN @Manual LIKE 'ISS%' THEN 0.60 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                    ELSE 0.50 
                                END

                            WHEN r.SpecialistProcedureRank > 1 AND r.RankWithinIncision = 1 THEN
                                CASE 
                                    WHEN @Manual = 'SOAT' THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                    WHEN @Manual LIKE 'ISS%' THEN 0.75 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                    ELSE 0.50 
                                END
                            ELSE 0.50
                        END

                    -- Operating Room Rights & Materials: Partitioned Strictly by Incision
                    WHEN r.SubtypeCode IN (4, 5) THEN
                        CASE 
                            WHEN r.IncisionSessionRank = 1 AND r.RankWithinIncision = 1 THEN
                                CASE 
                                    WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 
                                    ELSE 1.00 
                                END
                                
                            WHEN r.RankWithinIncision > 1 THEN 0.00

                            WHEN r.IncisionSessionRank > 1 AND r.RankWithinIncision = 1 THEN
                                CASE 
                                    WHEN @Manual = 'SOAT' THEN 0.75 * (CASE WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 ELSE 1.00 END)
                                    WHEN @Manual LIKE 'ISS%' THEN 0.50 * (CASE WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 ELSE 1.00 END)
                                    ELSE 0.50
                                END
                            ELSE 0.00
                        END

                    ELSE 1.00
                END AS DECIMAL(10,4)
            ) AS DegradationMultiplier
        FROM CatalogBaseUnits r
    ),
    FinalShiftAdjustments AS (
        SELECT 
            d.*,
            CAST(
                CASE 
                    WHEN d.RowShiftType IN (3, 4) AND d.SubtypeCode IN (1, 2) THEN 1.25 
                    ELSE 1.00 
                END AS DECIMAL(10,4)
            ) AS ShiftMultiplier,
            
            CASE 
                WHEN @Manual = 'SOAT' AND d.DateTimePerformed < '2024-01-01' THEN 'SMDLV'
                WHEN @Manual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 'UVB'
                WHEN @Manual LIKE 'ISS%' THEN 'UVR'
                ELSE 'COP' 
            END AS ValueBasis,
            
            ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
        FROM SurgicalDegradationRules d
        OUTER APPLY (
            SELECT TOP 1 BaseRate AS UnitValue 
            FROM ClinicalGeniusSupplyChain.dbo.UnitParameters up WITH(NOLOCK)
            WHERE up.ContractType = CASE WHEN d.ManualValue IS NOT NULL AND @Manual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
              AND up.CalendarYear = d.YearOfService
              AND up.UnitCategory = CASE WHEN d.DateTimePerformed >= '2024-01-01' AND @Manual = 'SOAT' THEN 'UVB'
                                         WHEN d.DateTimePerformed < '2024-01-01' AND @Manual = 'SOAT' THEN 'SMDLV'
                                         ELSE 'UVR' END
        ) up
    ),
    CalculatedLineItems AS (
        SELECT 
            f.*,
            CAST(
                CASE 
                    WHEN f.IsBundledInPackage = 1 THEN 0.00
                    ELSE (f.RawCatalogUnits * f.ShiftMultiplier * f.AppliedExceptionFactor * f.DegradationMultiplier * f.UnitMonetaryValue)
                END AS DECIMAL(18,2)
            ) AS CalculatedLineTotal
        FROM FinalShiftAdjustments f
    )

    -- TRACK A: PERSIST NORMALIZED SURGERY SUB-LINES
    INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
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
        CASE WHEN f.RankWithinIncision > 1 THEN 1 ELSE 0 END AS SameApproach, 
        f.RowShiftType,                     
        0.00 AS SurchargeAmount,                               
        f.CUPSCode,                         
        NULL AS CUMCode,                               
        f.DateTimePerformed,                
        GETDATE() AS DateTimeEntered,                          
        @Manual AS RevenueCode,                            
        1 AS Quantity,                                  
        f.SpecialistProcedureRank AS ItemCost,                    
        f.Laterality AS ItemSnomedCode,                       
        f.RawCatalogUnits AS ItemAlternateCode,                  
        f.AppliedExceptionFactor AS LocalAmount,              
        f.DegradationMultiplier AS USDBasePrice,            
        f.ShiftMultiplier AS USDPerItemChargeAmount,        
        f.ValueBasis AS PaymentType,                       
        f.CalculatedLineTotal AS NetAmount,                 
        0.00 AS TaxAmount,                               
        0.00 AS DiscountAmount,                               
        f.CalculatedLineTotal AS PerItemChargeAmount,       
        'Active' AS [Status]
    FROM CalculatedLineItems f;

    -- TRACK B: PERSIST MASTER BUNDLE ENTRIES (ONE MASTER ROW PER BUNDLE SESSION)
    INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
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
        'BundleMaster' AS TransactionType, 
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
        f.BundleCupsCode AS CupsCode,       
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
        f.BundlePrice AS NetAmount,         
        0.00 AS TaxAmount, 
        0.00 AS DiscountAmount, 
        f.BundlePrice AS PerItemChargeAmount, 
        'Active' AS [Status]
    FROM CalculatedLineItems f
    WHERE f.IsBundle = 1                    
    GROUP BY f.SurgeryGuid, f.BundleCupsCode, f.BundleDescription, f.BundlePrice, f.SurgeryApproach, f.DateTimePerformed;

    -- ==========================================================================================
    -- SECTION 5: Procedure-Linked High-Cost Carve-Out Charges
    -- ==========================================================================================
    INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
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
        @ClaimGuid,
        s.SurgeryGuid,
        @ContractGuid,
        NULL AS ContractExceptionGuid,          
        '04' AS Ambity,                         
        CAST(ISNULL(sc.BasePrice, 0.00) AS DECIMAL(18,2)) AS BaseUnitValue,
        ISNULL(sc.ItemDescription, 'Material Especial / Osteosintesis') AS SurgicalComponent,
        NULL AS SurgicalGroup,
        NULL AS SurgicalApproach,
        0 AS SameApproach,
        2 AS ShiftTypeApplied,                  
        0.00 AS SurchargeAmount,
        sc.ItemNumber AS CupsCode,             
        sc.ItemNumber AS CUMCode,              
        ISNULL(sc.DateTimeCompleted, s.DateTimePerformed) AS ExternalProcessedDateTime,
        GETDATE() AS DateTimeEntered,
        @Manual AS RevenueCode,
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
    INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeryProcedures sp WITH(NOLOCK)
        ON sp.SurgeryProcedureGuid = sc.SurgeryProcedureGuid
    INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK) 
        ON s.SurgeryGuid = sp.SurgeryGuid
    WHERE s.PatientVisit = @PatientVisit
      AND s.Status = 'Completed'
      AND sc.Facility = @FacilityId             
      AND sc.Active = 1                         
      AND ISNULL(sc.Billed, 0) = 0;

    -- Flag processed carve-outs to lock against double billing
    UPDATE sc
    SET sc.Billed = 1,
        sc.DateTimeBilled = GETDATE()
    FROM ClinicalGeniusEhr.dbo.ScheduledSurgeryCharges sc
    INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeryProcedures sp ON sp.SurgeryProcedureGuid = sc.SurgeryProcedureGuid
    INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s ON s.SurgeryGuid = sp.SurgeryGuid
    WHERE s.PatientVisit = @PatientVisit
      AND sc.Facility = @FacilityId
      AND sc.Active = 1
      AND ISNULL(sc.Billed, 0) = 0;

    -- ==========================================================================================
    -- SECTION 6a: Standalone Outpatient Procedures
    -- ==========================================================================================
    ;WITH OutpatientProcedureList AS (
        SELECT 
            pp.ProcedureGuid, pp.ProcedureCode, pp.ProcedureDescription, pp.LaterialityCode, pp.ServiceGroup,
            ISNULL(amx.Ambity, '01') AS Ambity, 
            CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATValue 
                 WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Value
                 ELSE mvx.ISS2004Value END AS CatalogValue,
            CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATSurgeryGrp 
                 WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
                 ELSE mvx.ISS2004SurgeryGrp END AS SurgeryGroup,
            CASE WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
                 WHEN @Manual = 'ISS_2001' THEN mvx.ISS2001Article
                 ELSE mvx.ISS2004Article END AS ArticleGroup,
            ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS TargetDate,
            YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) AS YearOfService,
            CASE 
                WHEN h.HolidayDate IS NOT NULL THEN 4
                WHEN DATENAME(weekday, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) = 'Sunday' THEN 4 
                WHEN DATEPART(hour, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) < 7 THEN 3 
                WHEN DATEPART(hour, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) > 18 THEN 3
                ELSE 2 
            END AS RowShiftType
        FROM ClinicalGeniusEhr.dbo.PatientProcedures pp WITH(NOLOCK)
        LEFT JOIN #ColombianHolidays h ON h.HolidayDate = CAST(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS DATE)
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
            WHERE mvl.CUPSCode = pp.ProcedureCode 
              AND mvl.YearOfService = YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered))
        ) mvx
        WHERE pp.PatientVisit = @PatientVisit 
          AND pp.Active = 1
          AND pp.Facility = @FacilityId
    ),
    AllMatchingProcedureExceptions AS (
        SELECT 
            opl.*,
            ce.PriceModifier AS ExceptionPriceModifier, 
            ce.ExceptionGuid,
            ROW_NUMBER() OVER (
                PARTITION BY opl.ProcedureGuid
                ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.ExceptionGuid ASC 
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
            ISNULL(ExceptionPriceModifier, 0.00) AS PriceModifier 
        FROM AllMatchingProcedureExceptions
        WHERE ExceptionPriorityRank = 1 
    ),
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
                WHEN @Manual LIKE 'ISS%' THEN 'UVR'
                ELSE 'COP' 
            END AS ValueBasis,
            ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
        FROM OutpatientBaseUnits b
        OUTER APPLY (
            SELECT TOP 1 BaseRate AS UnitValue 
            FROM ClinicalGeniusSupplyChain.dbo.UnitParameters up WITH(NOLOCK)
            WHERE up.ContractType = CASE WHEN @Manual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
              AND up.CalendarYear = b.YearOfService
              AND up.UnitCategory = CASE WHEN b.TargetDate >= '2024-01-01' AND @Manual = 'SOAT' THEN 'UVB'
                                         WHEN b.TargetDate < '2024-01-01' AND @Manual = 'SOAT' THEN 'SMDLV'
                                         ELSE 'UVR' END
        ) up
    ),
    CalculatedOutpatientLines AS (
        SELECT 
            o.*,
            CAST(o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue * o.UnitMonetaryValue AS DECIMAL(18,2)) AS OutpatientLineTotal
        FROM OutpatientFinalShiftAdjustments o
    )
    INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
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
        ISNULL(f.Ambity, '02') AS Ambity,    
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
    -- SECTION 6b: Inpatient Stay Days (Estancias) Expansion
    -- ==========================================================================================
    ;WITH Tally(n) AS (
        SELECT TOP 1000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
        FROM sys.all_columns a
        CROSS JOIN (SELECT TOP 2 * FROM sys.all_columns) b
    ),
    ExpandedStayDays AS (
        SELECT 
            hos.StayGuid,
            hos.PatientVisit,
            hos.BedCategoryCode,   
            hos.FacilityId,
            CAST(DATEADD(DAY, t.n, hos.AdmissionDateTime) AS DATE) AS StayCalendarDate,
            YEAR(DATEADD(DAY, t.n, hos.AdmissionDateTime)) AS YearOfService
        FROM ClinicalGeniusEhr.dbo.PatientHospitalStays hos WITH(NOLOCK)
        INNER JOIN Tally t ON t.n <= DATEDIFF(DAY, hos.AdmissionDateTime, ISNULL(hos.DischargeDateTime, GETDATE()))
        WHERE hos.PatientVisit = @PatientVisit
          AND hos.Status = 'Completed'
          AND hos.FacilityId = @FacilityId
    ),
    StaysWithTariffBaselines AS (
        SELECT 
            es.*,
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
            SELECT TOP 1 
                SOATValue, ISS2001Value, ISS2004Value,
                SOATArticle, ISS2001Article, ISS2004Article
            FROM ClinicalGeniusSupplyChain.dbo.ManualValues mvl WITH(NOLOCK)
            WHERE mvl.CUPSCode = es.BedCategoryCode
              AND mvl.YearOfService = es.YearOfService
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
            ON ce.ContractGuid = @ContractGuid 
            AND ce.Active = 1 
            AND st.StayCalendarDate >= ce.StartDate 
            AND st.StayCalendarDate <= ISNULL(ce.EndDate, '9999-12-31') 
            AND ce.ArticleGroup = st.ArticleGroup
            AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '03') 
    ),
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
            ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
        FROM AllMatchingStayExceptions ex
        OUTER APPLY (
            SELECT TOP 1 BaseRate AS UnitValue 
            FROM ClinicalGeniusSupplyChain.dbo.UnitParameters up WITH(NOLOCK)
            WHERE up.ContractType = CASE WHEN @Manual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
              AND up.CalendarYear = ex.YearOfService
              AND up.UnitCategory = CASE WHEN ex.StayCalendarDate >= '2024-01-01' AND @Manual = 'SOAT' THEN 'UVB'
                                         WHEN ex.StayCalendarDate < '2024-01-01' AND @Manual = 'SOAT' THEN 'SMDLV'
                                         ELSE 'UVR' END
        ) up
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
    INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
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
        'Stay' AS TransactionType,         
        @ClaimGuid, 
        NULL AS SurgeryGuid, 
        @ContractGuid, 
        f.ExceptionGuid, 
        '03' AS Ambity,                    
        f.UnitMonetaryValue, 
        'Día de Estancia Hosp: Category Code ' + f.BedCategoryCode, 
        NULL AS SurgicalGroup, 
        NULL AS SurgicalApproach, 
        0 AS SameApproach, 
        2 AS ShiftTypeApplied,             
        0.00 AS SurchargeAmount, 
        f.BedCategoryCode AS CupsCode, 
        NULL AS CUMCode, 
        CAST(f.StayCalendarDate AS DATETIME), 
        GETDATE() AS DateTimeEntered, 
        @Manual AS RevenueCode, 
        1 AS Quantity,                     
        0.00 AS ItemCost, 
        NULL AS ItemSnomedCode, 
        f.RoomCatalogUnits AS ItemAlternateCode, 
        f.BaseCalculatedValue AS LocalAmount, 
        1.00 AS USDBasePrice, 
        1.00 AS USDPerItemChargeAmount, 
        f.ValueBasis AS PaymentType, 
        f.DayLineNetAmount AS NetAmount,    
        0.00 AS TaxAmount, 
        0.00 AS DiscountAmount, 
        f.DayLineNetAmount AS PerItemChargeAmount, 
        'Active' AS [Status]
    FROM FinalStayLiquidationLines f;

    -- ==========================================================================================
    -- SECTION 6c: Medication Formularies & Surgical Absorption Matrix
    -- ==========================================================================================
    ;WITH ActiveMedicationList AS (
        SELECT 
            mar.PatientId, mar.PatientVisit, mar.MedicationCode, mar.MedicationName, mar.ActualDoseGiven, mar.QuantityUnit, mar.Facility,
            ISNULL(amx.Ambity, '01') AS Ambity, 
            ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) AS TargetDate,
            YEAR(ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) AS YearOfService,
            CAST(ISNULL(df.BasePrice, 0.00) AS DECIMAL(18,2)) AS FormularyBasePrice,
            CAST(ISNULL(df.Cost, 0.00) AS DECIMAL(18,2)) AS FormularyUnitCost,
            CAST(
                CASE 
                    WHEN s.IsBundle = 1 AND s.MedicationIncluded = 1 THEN 1 
                    ELSE 0 
                END AS BIT
            ) AS IsBundledInPackage,
            s.SurgeryGuid,
            CASE 
                WHEN h.HolidayDate IS NOT NULL THEN 4
                WHEN DATENAME(weekday, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) = 'Sunday' THEN 4 
                WHEN DATEPART(hour, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) < 7 THEN 3 
                WHEN DATEPART(hour, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) > 18 THEN 3
                ELSE 2 
            END AS RowShiftType
        FROM ClinicalGeniusEhr.dbo.MedicationAdministrationRecords mar WITH(NOLOCK)
        INNER JOIN ClinicalGeniusSupplyChain.dbo.DrugFormulary df WITH(NOLOCK) 
            ON df.MedicationCode = mar.MedicationCode
        LEFT JOIN #ColombianHolidays h 
            ON h.HolidayDate = CAST(ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) AS DATE)
        OUTER APPLY (
            SELECT TOP 1 DPT.Ambity 
            FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
            INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) 
                ON DPT.DepartmentGuid = PDT.DepartmentGuid
            WHERE PDT.PatientVisit = @PatientVisit 
              AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) > PDT.StartDateTime 
              AND (ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
            ORDER BY PDT.StartDateTime DESC 
        ) amx
        LEFT JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
            ON s.PatientVisit = mar.PatientVisit
            AND s.Status = 'Completed'
            AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) >= s.DateTimePerformed
            AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) <= DATEADD(HOUR, 4, s.DateTimePerformed)
        WHERE mar.PatientVisit = @PatientVisit
          AND mar.Status = 'Completed'
          AND mar.Facility = @FacilityId
          AND mar.ActualDoseGiven > 0
    ),
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
    CalculatedMedicationLines AS (
        SELECT 
            e.*,
            CAST(1 + (@AdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
            CAST(
                CASE 
                    WHEN e.IsBundledInPackage = 1 THEN 0.00
                    ELSE (e.ActualDoseGiven * e.FormularyBasePrice) * CAST(1 + (@AdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4))
                END AS DECIMAL(18,2)
            ) AS MedicationLineTotal
        FROM AllMatchingMedicationExceptions e
        WHERE e.ExceptionPriorityRank = 1
    )
    INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
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
        @ClaimGuid, 
        f.SurgeryGuid,                         
        @ContractGuid, 
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
        f.MedicationLineTotal AS NetAmount,    
        0.00 AS TaxAmount,                               
        0.00 AS DiscountAmount,                               
        f.MedicationLineTotal AS PerItemChargeAmount, 
        'Active' AS [Status]
    FROM CalculatedMedicationLines f;

    -- ==========================================================================================
    -- SECTION 6d: Laboratory & Pathology Diagnostic Panels
    -- ==========================================================================================
    ;WITH CompletedLabPanels AS (
        SELECT 
            lto.OrderGuid,
            lto.CPTCode AS PanelCupsCode,      
            lto.CPTDescription AS PanelDescription,
            lto.PatientVisit,
            lto.Facility AS FacilityId,
            ISNULL(lto.PinDate, lto.DateTimeScheduled) AS CompletionDate, 
            YEAR(ISNULL(lto.PinDate, lto.DateTimeScheduled)) AS YearOfService,
            ISNULL(amx.Ambity, '02') AS Ambity, 
            CASE 
                WHEN h.HolidayDate IS NOT NULL THEN 4
                WHEN DATENAME(weekday, ISNULL(lto.PinDate, lto.DateTimeScheduled)) = 'Sunday' THEN 4 
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
                          AND s.MaterialIncluded = 1 
                          AND ISNULL(lto.PinDate, lto.DateTimeScheduled) >= s.DateTimePerformed
                          AND ISNULL(lto.PinDate, lto.DateTimeScheduled) <= DATEADD(HOUR, 6, s.DateTimePerformed)
                    ) THEN 1 
                    ELSE 0 
                END AS BIT
            ) AS IsLabAbsorbedByBundle
        FROM ClinicalGeniusEhr.dbo.PatientLabTestOrders lto WITH(NOLOCK)
        LEFT JOIN #ColombianHolidays h 
            ON h.HolidayDate = CAST(ISNULL(lto.PinDate, lto.DateTimeScheduled) AS DATE)
        OUTER APPLY (
            SELECT TOP 1 DPT.Ambity 
            FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
            INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) 
                ON DPT.DepartmentGuid = PDT.DepartmentGuid
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
    LabLinesWithTariffs AS (
        SELECT 
            cl.*,
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
            ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
        FROM AllMatchingLabExceptions e
        OUTER APPLY (
            SELECT TOP 1 BaseRate AS UnitValue 
            FROM ClinicalGeniusSupplyChain.dbo.UnitParameters up WITH(NOLOCK)
            WHERE up.ContractType = CASE WHEN @Manual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
              AND up.CalendarYear = e.YearOfService
              AND up.UnitCategory = CASE WHEN e.CompletionDate >= '2024-01-01' AND @Manual = 'SOAT' THEN 'UVB'
                                         WHEN e.CompletionDate < '2024-01-01' AND @Manual = 'SOAT' THEN 'SMDLV'
                                         ELSE 'UVR' END
        ) up
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
    INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
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

    -- ==========================================================================================
    -- SECTION 6e: Diagnostic Imaging Services (Catalog CPT Aligned)
    -- ==========================================================================================
    ;WITH CompletedImagingOrders AS (
        SELECT 
            img.ImagingOrderGuid,
            ioi.CPTCode AS ImagingCupsCode,       
            img.ImagingOrderDescription AS ImagingDescription,
            img.PatientVisit,
            img.Facility AS FacilityId,
            ISNULL(img.DateTimeUpdated, img.DateTimeEntered) AS CompletionDate, 
            YEAR(ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) AS YearOfService,
            ISNULL(amx.Ambity, '02') AS Ambity,    
            CASE 
                WHEN h.HolidayDate IS NOT NULL THEN 4
                WHEN DATENAME(weekday, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) = 'Sunday' THEN 4 
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
                          AND s.MaterialIncluded = 1 
                          AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) >= s.DateTimePerformed
                          AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) <= DATEADD(HOUR, 6, s.DateTimePerformed)
                    ) THEN 1 
                    ELSE 0 
                END AS BIT
            ) AS IsImagingAbsorbedByBundle
        FROM ClinicalGeniusEhr.dbo.PatientImagingOrders img WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.ImagingOrderItems ioi WITH(NOLOCK)
            ON ioi.ImageOrderItemGuid = img.ImageOrderItemGuid
        LEFT JOIN #ColombianHolidays h 
            ON h.HolidayDate = CAST(ISNULL(img.DateTimeUpdated, img.DateTimeEntered) AS DATE)
        OUTER APPLY (
            SELECT TOP 1 DPT.Ambity 
            FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
            INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) 
                ON DPT.DepartmentGuid = PDT.DepartmentGuid
            WHERE PDT.PatientVisit = img.PatientVisit 
              AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) > PDT.StartDateTime 
              AND (ISNULL(img.DateTimeUpdated, img.DateTimeEntered) < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
            ORDER BY PDT.StartDateTime DESC
        ) amx
        WHERE img.PatientVisit = @PatientVisit 
          AND img.OrderStatus = 'Completed'     
          AND img.Facility = @FacilityId         
    ),
    ImagingLinesWithTariffs AS (
        SELECT 
            io.*,
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
            ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
        FROM AllMatchingImagingExceptions e
        OUTER APPLY (
            SELECT TOP 1 BaseRate AS UnitValue 
            FROM ClinicalGeniusSupplyChain.dbo.UnitParameters up WITH(NOLOCK)
            WHERE up.ContractType = CASE WHEN @Manual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
              AND up.CalendarYear = e.YearOfService
              AND up.UnitCategory = CASE WHEN e.CompletionDate >= '2024-01-01' AND @Manual = 'SOAT' THEN 'UVB'
                                         WHEN e.CompletionDate < '2024-01-01' AND @Manual = 'SOAT' THEN 'SMDLV'
                                         ELSE 'UVR' END
        ) up
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
    INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
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
        f.ImagingCupsCode AS CupsCode,       
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

    -- ==========================================================================================
    -- SECTION 7: Statutory Co-Payment Capping Protection
    -- ==========================================================================================
    DECLARE @PatientFinancialClass VARCHAR(5) = 'A',
            @MaxAllowedCopayPerEvent DECIMAL(18,2) = 99999999.99,
            @CurrentCalculatedVisitCopay DECIMAL(18,2) = 0.00;

    SELECT TOP 1 
        @PatientFinancialClass = pat.FinancialClass
    FROM ClinicalGeniusEhr.dbo.PatientTable pat WITH(NOLOCK)
    WHERE pat.PatientId = @PatientId;

    SELECT TOP 1 
        @MaxAllowedCopayPerEvent = scl.MaxCapPerEvent
    FROM ClinicalGeniusSupplyChain.dbo.StatutoryCopayLimits scl WITH(NOLOCK)
    WHERE scl.CalendarYear = YEAR(GETDATE())
      AND scl.FinancialClass = @PatientFinancialClass;

    IF @MaxAllowedCopayPerEvent IS NULL
        SET @MaxAllowedCopayPerEvent = 99999999.99;

    SELECT TOP 1
        @CurrentCalculatedVisitCopay = ISNULL(pyc.Copay, 0.00) + ISNULL(pyc.MedicalCoinsurance, 0.00)
    FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
    WHERE pyc.ClaimGuid = @ClaimGuid
      AND pyc.FacilityId = @FacilityId;

    IF @CurrentCalculatedVisitCopay > @MaxAllowedCopayPerEvent
    BEGIN
        UPDATE pyc
        SET pyc.Copay = CASE WHEN @PatientFinancialClass = 'S1' THEN 0.00 ELSE @MaxAllowedCopayPerEvent END,
            pyc.MedicalCoinsurance = 0.00,
            pyc.PayerCoverageAmount = pyc.PayerCoverageAmount + (@CurrentCalculatedVisitCopay - @MaxAllowedCopayPerEvent),
            pyc.LastUpdatedBy = 'CopayCappingMatrix'
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc
        WHERE pyc.ClaimGuid = @ClaimGuid
          AND pyc.FacilityId = @FacilityId;
    END;

    COMMIT TRANSACTION;
    SELECT 'LIQUIDATION COMPLETED: Complete multi-pillar batch successfully posted' AS LiquidationStatus;

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(),
            @ErrorSeverity INT = ERROR_SEVERITY(),
            @ErrorState INT = ERROR_STATE();

    RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
END CATCH;

-- Final session cleanup
IF OBJECT_ID('tempdb..#ColombianHolidays') IS NOT NULL DROP TABLE #ColombianHolidays;