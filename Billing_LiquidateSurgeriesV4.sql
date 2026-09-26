CREATE OR ALTER PROCEDURE ClinicalGeniusSupplyChain.dbo.Billing_LiquidateSurgeries
    @PatientVisit   NVARCHAR(50),
    @FacilityId     NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ==========================================================================================
    -- 1. Context Resolution (Default Claim & Patient)
    -- ==========================================================================================
    DECLARE @DefaultClaimGuid NVARCHAR(50);
    DECLARE @PatientId        NVARCHAR(50);

    SELECT TOP 1 
        @DefaultClaimGuid = pyc.ClaimGuid,
        @PatientId        = pyc.PatientId
    FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
    WHERE pyc.PatientVisit = @PatientVisit
      AND pyc.FacilityId = @FacilityId
      AND pyc.Status = 'Pending'
    ORDER BY pyc.BatchNumber ASC;

    -- Fallback baseline if uninsured or self-pay
    IF @PatientId IS NULL
    BEGIN
        SELECT TOP 1 @PatientId = PatientId
        FROM ClinicalGeniusEhr.dbo.PatientVisits WITH(NOLOCK)
        WHERE PatientVisitUniqueId = @PatientVisit AND FacilityId = @FacilityId;
    END;

    -- Pre-load Colombian legal holidays scoped to this execution
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

    -- Pre-load Unit Parameters globally
    IF OBJECT_ID('tempdb..#UnitParameters') IS NOT NULL DROP TABLE #UnitParameters;
    CREATE TABLE #UnitParameters (
        ContractType VARCHAR(10),
        CalendarYear INT,
        UnitCategory VARCHAR(10),
        UnitValue DECIMAL(18,2)
    );
    INSERT INTO #UnitParameters (ContractType, CalendarYear, UnitCategory, UnitValue)
    VALUES
        ('SOAT', 2023, 'SMDLV', 38666.67),
        ('SOAT', 2024, 'UVB', 10951.00),
        ('SOAT', 2025, 'UVB', 11552.00),
        ('SOAT', 2026, 'UVB', 12110.00),
        ('ISS',  2023, 'UVR', 1.00),
        ('ISS',  2024, 'UVR', 1.00),
        ('ISS',  2025, 'UVR', 1.00),
        ('ISS',  2026, 'UVR', 1.00);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ==========================================================================================
        -- 2. Targeted Staging Clear (Surgical Scope ONLY)
        -- ==========================================================================================
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Surgeries'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType IN ('Surgery', 'RoomRights', 'Supplies', 'Honorary', 'BundleMaster')
          AND Status <> 'Canceled'
          AND (ElectronicInvoiceStatus IS NULL OR ElectronicInvoiceStatus <> 'Transmitted');

        -- Reset Billed flag on carve-out supplies to re-liquidate cleanly
        UPDATE sc
        SET sc.Billed = 0,
            sc.DateTimeBilled = NULL
        FROM ClinicalGeniusEhr.dbo.ScheduledSurgeryCharges sc WITH(ROWLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.SurgeryProcedures sp ON sp.SurgeryProcedureGuid = sc.SurgeryProcedureGuid
        INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s ON s.SurgeryGuid = sp.SurgeryGuid
        WHERE s.PatientVisit = @PatientVisit
          AND sc.Facility = @FacilityId
          AND sc.Active = 1
          AND sc.Billed = 1;

        -- ==========================================================================================
        -- 3. Execution Pipeline Matrix
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
        SurgeryContext AS (
            SELECT 
                s.SurgeryGuid,
                s.DateTimePerformed,
                CAST(ISNULL(s.IsBundle, 0) AS BIT) AS IsBundle,
                s.BundleDescription,
                CAST(ISNULL(s.BundlePrice, 0.00) AS DECIMAL(18,2)) AS BundlePrice,
                CAST(ISNULL(s.SurgeonIncluded, 0) AS BIT) AS SurgeonIncluded,
                CAST(ISNULL(s.AnesthesiologistIncluded, 0) AS BIT) AS AnesthesiologistIncluded,
                CAST(ISNULL(s.AssistantIncluded, 0) AS BIT) AS AssistantIncluded,
                CAST(ISNULL(s.RoomIncluded, 0) AS BIT) AS RoomIncluded,
                CAST(ISNULL(s.MaterialIncluded, 0) AS BIT) AS MaterialIncluded,
                CAST(ISNULL(s.MedicationIncluded, 0) AS BIT) AS MedicationIncluded,
                ISNULL(s.ClaimGuid, @DefaultClaimGuid) AS ResolvedClaimGuid,
                contract_info.ContractGuid AS ResolvedContractGuid,
                ISNULL(contract_info.EntityCode, 'SOAT') AS ResolvedManual,
                ISNULL(contract_info.AdjustmentPct, 0.00) AS ResolvedAdjustmentPct
            FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
            OUTER APPLY (
                SELECT TOP 1 
                    ppy_s.ContractGuid,
                    isc_s.EntityCode,
                    isc_s.AdjustmentPct
                FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc_s WITH(NOLOCK)
                INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy_s WITH(NOLOCK) 
                    ON ppy_s.PatientPayerGuid = pyc_s.PayerGuid
                INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc_s WITH(NOLOCK) 
                    ON isc_s.ContractGuid = ppy_s.ContractGuid
                WHERE pyc_s.ClaimGuid = ISNULL(s.ClaimGuid, @DefaultClaimGuid)
            ) contract_info
            WHERE s.PatientVisit = @PatientVisit 
              AND s.Status = 'Completed'
              AND s.Facility = @FacilityId
              AND ISNULL(s.NoBill, 0) = 0
        ),
        RawProcedureEntries AS (
            SELECT 
                scx.*,
                sp.SurgeryProcedureGuid,
                sp.Laterality, 
                sp.SurgeryApproach,
                sp.SurgeonId,
                sp.Anesthesiologist,          
                sp.Assistant1 AS SurgeonId2,  
                sp.Assistant2 AS SurgeonId3,  
                ISNULL(sp.IncisionNumber, 1) AS IncisionNumber,
                sp.IsPrimary AS IsClinicalPrimary,
                ISNULL(sp.NoBill, 0) AS NoBill, 
                YEAR(scx.DateTimePerformed) AS YearOfService,
                sp.ProcedureGuid,
                actual_prim.PrimaryPerformedCupsCode AS BundleCupsCode,
                CASE 
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN DATENAME(weekday, scx.DateTimePerformed) = 'Sunday' THEN 4 
                    WHEN DATEPART(hour, scx.DateTimePerformed) < 7 THEN 3 
                    WHEN DATEPART(hour, scx.DateTimePerformed) > 18 THEN 3
                    ELSE 2 
                END AS RowShiftType
            FROM SurgeryContext scx
            INNER JOIN ClinicalGeniusEhr.dbo.SurgeryProcedures sp WITH(NOLOCK)
                ON sp.SurgeryGuid = scx.SurgeryGuid AND sp.Active = 1
            LEFT JOIN #ColombianHolidays h ON h.HolidayDate = CAST(scx.DateTimePerformed AS DATE)
            OUTER APPLY (
                SELECT TOP 1 pai_prim.RVSCode AS PrimaryPerformedCupsCode
                FROM ClinicalGeniusEhr.dbo.SurgeryProcedures sp_prim WITH(NOLOCK)
                INNER JOIN ClinicalGeniusEhr.dbo.ProcedureAdministrationItems pai_prim WITH(NOLOCK)
                    ON sp_prim.ProcedureGuid = pai_prim.ProcedureGuid
                WHERE sp_prim.SurgeryGuid = scx.SurgeryGuid
                  AND sp_prim.Active = 1
                ORDER BY sp_prim.IsPrimary DESC, sp_prim.IncisionNumber ASC
            ) actual_prim
        ),
        ProceduresWithCodes AS (
            SELECT 
                rp.*, 
                CASE WHEN rp.ResolvedManual = 'SOAT' THEN mvx.SOATValue 
                     WHEN rp.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Value
                     ELSE 0.00 END AS ManualValue,
                CASE WHEN rp.ResolvedManual = 'SOAT' THEN mvx.SOATSurgeryGrp 
                     WHEN rp.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001SurgeryGrp
                     ELSE NULL END AS SurgeryGroup,
                CASE WHEN rp.ResolvedManual = 'SOAT' THEN mvx.SOATArticle 
                     WHEN rp.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article
                     ELSE NULL END AS ArticleGroup,
                pai.RVSCode AS CUPSCode
            FROM RawProcedureEntries rp
            INNER JOIN ClinicalGeniusEhr.dbo.ProcedureAdministrationItems pai WITH(NOLOCK) 
                ON rp.ProcedureGuid = pai.ProcedureGuid 
            OUTER APPLY (
                SELECT TOP 1 
                    SOATValue, ISS2001Value,
                    SOATSurgeryGrp, ISS2001SurgeryGrp,
                    SOATArticle, ISS2001Article
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
                        pw.NoBill ASC, 
                        CASE WHEN pw.ResolvedManual = 'SOAT' THEN pw.SurgeryGroup ELSE 0 END DESC,
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
                        CASE WHEN ih.ResolvedManual = 'SOAT' THEN ih.SurgeryGroup ELSE 0 END DESC,
                        ISNULL(ih.ManualValue, 0.00) DESC,
                        ih.SurgeryProcedureGuid ASC
                ) AS SpecialistProcedureRank
            FROM IncisionHierarchy ih
        ),
        AllMatchingExceptions AS (
            SELECT 
                p.*, 
                ce.Ranking AS ExceptionRanking,
                ce.PriceValue AS ExceptionPriceValue,
                ISNULL(ce.PriceModifier, 0.00) AS PriceModifier, 
                ce.ExceptionGuid,
                ROW_NUMBER() OVER (
                    PARTITION BY p.SurgeryProcedureGuid
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC 
                ) AS ExceptionPriorityRank
            FROM SpecialistHierarchy p
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
                ON ce.ContractGuid = p.ResolvedContractGuid 
                AND ce.Active = 1 
                AND CAST(p.DateTimePerformed AS DATE) >= ce.StartDate 
                AND CAST(p.DateTimePerformed AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
                AND (ce.Ranking <> 1 OR ce.ExceptionType = p.ArticleGroup)
                AND (ce.Ranking <> 2 OR ce.SurgeryGrp = p.SurgeryGroup) 
                AND (ce.Ranking NOT IN (3, 4, 5, 6, 7, 8) OR ce.CupsCode = p.CUPSCode) 
                AND (ce.ShiftType = 1 OR ce.ShiftType = p.RowShiftType) 
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '04')
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
                        WHEN pe.IsBundle = 1 AND v.SubtypeCode = 1 AND pe.SurgeonIncluded = 1          THEN 1 
                        WHEN pe.IsBundle = 1 AND v.SubtypeCode = 2 AND pe.AnesthesiologistIncluded = 1 THEN 1 
                        WHEN pe.IsBundle = 1 AND v.SubtypeCode IN (3, 6) AND pe.AssistantIncluded = 1  THEN 1 
                        WHEN pe.IsBundle = 1 AND v.SubtypeCode = 4 AND pe.RoomIncluded = 1             THEN 1 
                        WHEN pe.IsBundle = 1 AND v.SubtypeCode = 5 AND pe.MaterialIncluded = 1         THEN 1 
                        ELSE 0 
                    END AS BIT
                ) AS IsBundledInPackage,
                CAST(1 + (pe.ResolvedAdjustmentPct / 100.00) + (ISNULL(pe.PriceModifier, 0.00) / 100.00) AS DECIMAL(10,4)) AS AppliedExceptionFactor
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
                        WHEN f.ResolvedManual = 'SOAT' AND f.SubtypeCode = 3 AND f.SurgeryGroup <= 5  THEN 0.00
                        WHEN f.ResolvedManual = 'SOAT' AND f.SubtypeCode = 6 AND f.SurgeryGroup <= 10 THEN 0.00
                        WHEN f.ResolvedManual = 'SOAT' THEN ISNULL(soat.BaseUnits, 0.00)
                        WHEN f.ResolvedManual LIKE 'ISS%' AND f.SubtypeCode IN (1, 2, 3, 6) THEN ISNULL(f.ManualValue, 0.00)
                        WHEN f.ResolvedManual LIKE 'ISS%' AND f.SubtypeCode IN (4, 5)       THEN ISNULL(iss.FacilityUvrPoints, 0.00)
                        ELSE 0.00 
                    END AS DECIMAL(18,2)
                ) AS RawCatalogUnits
            FROM RemoveMissingStaff f 
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
        SurgicalDegradationRules AS (
            SELECT 
                r.*,
                CAST(
                    CASE 
                        -- Professional Fees: Partitioned by Specialist & Incision
                        WHEN r.SubtypeCode IN (1, 2, 3, 6) THEN
                            CASE 
                                WHEN r.SpecialistProcedureRank = 1 THEN 
                                    CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END
                                
                                WHEN r.SpecialistProcedureRank > 1 AND r.RankWithinIncision > 1 THEN
                                    CASE 
                                        WHEN r.ResolvedManual = 'SOAT'      THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                        WHEN r.ResolvedManual LIKE 'ISS%'   THEN 0.60 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                        ELSE 0.50 
                                    END

                                WHEN r.SpecialistProcedureRank > 1 AND r.RankWithinIncision = 1 THEN
                                    CASE 
                                        WHEN r.ResolvedManual = 'SOAT'      THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                        WHEN r.ResolvedManual LIKE 'ISS%'   THEN 0.75 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
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
                                        WHEN r.ResolvedManual = 'SOAT'      THEN 0.75 * (CASE WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 ELSE 1.00 END)
                                        WHEN r.ResolvedManual LIKE 'ISS%'   THEN 0.50 * (CASE WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 ELSE 1.00 END)
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
                    WHEN d.ResolvedManual = 'SOAT' AND d.DateTimePerformed < '2024-01-01' THEN 'SMDLV'
                    WHEN d.ResolvedManual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 'UVB'
                    WHEN d.ResolvedManual LIKE 'ISS%' THEN 'UVR'
                    ELSE 'COP' 
                END AS ValueBasis,
                
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM SurgicalDegradationRules d
            OUTER APPLY (
                SELECT TOP 1 UnitValue 
                FROM #UnitParameters up 
                WHERE up.ContractType = CASE WHEN d.ManualValue IS NOT NULL AND d.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up.CalendarYear = d.YearOfService
                  AND up.UnitCategory = CASE WHEN d.DateTimePerformed >= '2024-01-01' AND d.ResolvedManual = 'SOAT' THEN 'UVB'
                                             WHEN d.DateTimePerformed < '2024-01-01' AND d.ResolvedManual = 'SOAT'  THEN 'SMDLV'
                                             ELSE 'UVR' END
            ) up
        ),
        CalculatedLineItems AS (
            SELECT 
                f.*,
                CAST(
                    CASE 
                        WHEN f.NoBill = 1 THEN 0.00
                        WHEN f.IsBundledInPackage = 1 THEN 0.00
                        -- NEW: Flat COP Exception Override (Rankings 3, 5, 7, 8)
                        WHEN f.ExceptionRanking IN (3, 5, 7, 8) THEN f.ExceptionPriceValue * f.ShiftMultiplier
                        -- Standard % Modifier Calculation
                        ELSE (f.RawCatalogUnits * f.ShiftMultiplier * f.AppliedExceptionFactor * f.DegradationMultiplier * f.UnitMonetaryValue)
                    END AS DECIMAL(18,2)
                ) AS CalculatedLineTotal
            FROM FinalShiftAdjustments f
        )

        -- Track A: Individual Surgical Sub-Lines
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
            CASE 
                WHEN f.SubtypeCode IN (1, 2, 3, 6) THEN 'Honorary'
                WHEN f.SubtypeCode IN (4, 5) THEN 'RoomRights'
                ELSE 'Surgery'
            END AS TransactionType,       
            f.ResolvedClaimGuid,                         
            f.SurgeryGuid, 
            f.ResolvedContractGuid, 
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
            f.ResolvedManual AS RevenueCode,                            
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
            CASE WHEN f.NoBill = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status] 
        FROM CalculatedLineItems f;

        -- Track B: Bundle Master Header Line
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
            f.ResolvedClaimGuid, 
            f.SurgeryGuid, 
            f.ResolvedContractGuid, 
            NULL AS ContractExceptionGuid, 
            '04' AS Ambity, 
            f.BundlePrice AS BaseUnitValue, 
            'Paquete Completo' AS SurgicalComponent, 
            NULL AS SurgicalGroup, 
            MAX(f.SurgeryApproach) AS SurgicalApproach, 
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
        GROUP BY f.SurgeryGuid, f.BundleCupsCode, f.BundleDescription, f.BundlePrice, f.DateTimePerformed, f.ResolvedClaimGuid, f.ResolvedContractGuid, f.ResolvedManual;

        -- Track C: Procedure-Linked Carve-Out Charges
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
            scx.ResolvedClaimGuid AS ClaimGuid,
            scx.SurgeryGuid,
            scx.ResolvedContractGuid AS ContractGuid,
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
            ISNULL(sc.DateTimeCompleted, scx.DateTimePerformed) AS ExternalProcessedDateTime,
            GETDATE() AS DateTimeEntered,
            scx.ResolvedManual AS RevenueCode,
            ISNULL(sc.Quantity, 1) AS Quantity,
            CAST(ISNULL(sc.ItemCost, 0.00) AS DECIMAL(18,2)) AS ItemCost, 
            NULL AS ItemSnomedCode,
            sc.ConsumedUOM AS ItemAlternateCode,    
            CAST(CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 0.00 ELSE ISNULL(sc.ChargeBasePrice, 0.00) END AS DECIMAL(10,4)) AS LocalAmount,
            1.00 AS USDBasePrice,
            1.00 AS USDPerItemChargeAmount,
            'COP' AS PaymentType,                   
            CAST(CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 0.00 ELSE ISNULL(sc.NetAmount, 0.00) END AS DECIMAL(18,2)) AS NetAmount, 
            CAST(CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 0.00 ELSE ISNULL(sc.TaxAmount, 0.00) END AS DECIMAL(18,2)) AS TaxAmount,
            CAST(CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 0.00 ELSE ISNULL(sc.DiscountAmount, 0.00) END AS DECIMAL(18,2)) AS DiscountAmount,
            CAST(CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 0.00 ELSE ISNULL(sc.NetAmount, 0.00) END AS DECIMAL(18,2)) AS PerItemChargeAmount,
            CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status]
        FROM ClinicalGeniusEhr.dbo.ScheduledSurgeryCharges sc WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.SurgeryProcedures sp WITH(NOLOCK)
            ON sp.SurgeryProcedureGuid = sc.SurgeryProcedureGuid
        INNER JOIN SurgeryContext scx 
            ON scx.SurgeryGuid = sp.SurgeryGuid
        WHERE sc.Facility = @FacilityId             
          AND sc.Active = 1                         
          AND ISNULL(sc.Billed, 0) = 0;

        -- Mark carve-outs as billed
        UPDATE sc
        SET sc.Billed = 1,
            sc.DateTimeBilled = GETDATE()
        FROM ClinicalGeniusEhr.dbo.ScheduledSurgeryCharges sc
        INNER JOIN ClinicalGeniusEhr.dbo.SurgeryProcedures sp ON sp.SurgeryProcedureGuid = sc.SurgeryProcedureGuid
        INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s ON s.SurgeryGuid = sp.SurgeryGuid
        WHERE s.PatientVisit = @PatientVisit
          AND sc.Facility = @FacilityId
          AND sc.Active = 1
          AND ISNULL(sc.Billed, 0) = 0;

        COMMIT TRANSACTION;
        SELECT 'SURGERIES LIQUIDATED SUCCESSFULLY' AS ExecutionStatus;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrSeverity INT       = ERROR_SEVERITY(),
                @ErrState INT          = ERROR_STATE();

        RAISERROR (@ErrMsg, @ErrSeverity, @ErrState);
    END CATCH;

    -- Clean up temporary tables
    IF OBJECT_ID('tempdb..#ColombianHolidays') IS NOT NULL DROP TABLE #ColombianHolidays;
    IF OBJECT_ID('tempdb..#UnitParameters') IS NOT NULL DROP TABLE #UnitParameters;
END;
GO