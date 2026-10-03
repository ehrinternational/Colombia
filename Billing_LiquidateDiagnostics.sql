USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLLiquidateDiagnostics ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE {odata}.{COLLiquidateDiagnostics}
    @PatientVisit    NVARCHAR(50),
    @FacilityId      NVARCHAR(50),
    @TargetClaimGuid NVARCHAR(50) 
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ==========================================================================================
    -- 1. Targeted Context Resolution
    -- ==========================================================================================
    DECLARE @ResolvedClaimGuid       NVARCHAR(50),
            @ResolvedContractGuid    NVARCHAR(50),
            @ResolvedManual          VARCHAR(20),
            @ResolvedAdjustmentPct   DECIMAL(5,2),
            @ResolvedNightCharges    Bit,
            @PatientId               NVARCHAR(50);

    SELECT TOP 1 @PatientId = PatientId
    FROM ClinicalGeniusEhr.dbo.PatientVisits WITH(NOLOCK)
    WHERE PatientVisitUniqueId = @PatientVisit AND FacilityId = @FacilityId;

    -- Route A: Patient Responsibility (Out-of-pocket / Unassigned items only)
    IF @TargetClaimGuid = 'Patient'
    BEGIN
        SET @ResolvedClaimGuid       = NULL;
        SET @ResolvedContractGuid    = NULL;
        SET @ResolvedManual          = 'SOAT';
        SET @ResolvedAdjustmentPct   = 0.00;
        SET @ResolvedNightCharges    = 0;
    END
    -- Route B: Explicit Payer Claim Targeted
    ELSE 
    BEGIN
        SELECT TOP 1 
            @ResolvedClaimGuid       = pyc.ClaimGuid,
            @ResolvedContractGuid    = isc.ContractGuid,
            @ResolvedManual          = ISNULL(isc.EntityCode, 'SOAT'),
            @ResolvedAdjustmentPct   = ISNULL(isc.AdjustmentPct, 0.00),
            @ResolvedNightCharges    = ISNULL(isc.NightCharges, 0)
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
            ON ppy.PatientPayerGuid = pyc.PayerGuid
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsurancePlans isp WITH(NOLOCK) 
            ON isp.PlanGuid = ppy.PayerPlan
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
            ON isc.ContractGuid = isp.ContractGuid
        WHERE pyc.ClaimGuid = @TargetClaimGuid
          AND pyc.FacilityId = @FacilityId;
    END

    -- Pre-load Colombian statutory holidays scoped to this diagnostic batch
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
        ('SOAT', 2027, 'UVB', 12110.00),
        ('ISS',  2023, 'UVR', 1.00),
        ('ISS',  2024, 'UVR', 1.00),
        ('ISS',  2025, 'UVR', 1.00),
        ('ISS',  2026, 'UVR', 1.00),
        ('ISS',  2027, 'UVR', 1.00);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ==========================================================================================
        -- 2. Auto-Assign Unassigned Diagnostics to Target Claim (When running for an insurance claim)
        -- ==========================================================================================
        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.PatientLabTestOrders WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND Status = 'Completed'
              AND ClaimGuid IS NULL;

            UPDATE ClinicalGeniusEhr.dbo.PatientImagingOrders WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND OrderStatus = 'Completed'
              AND ClaimGuid IS NULL;
        END

        -- ==========================================================================================
        -- 3. Targeted Staging Clear (Safeguards Invoiced Records)
        -- ==========================================================================================
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Diagnostics'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Diagnostics'
          AND SurgeryGuid IS NULL
          AND Status NOT IN ('Invoiced', 'Billed', 'Canceled') 
          AND (
              (@TargetClaimGuid = 'Patient' AND ClaimGuid IS NULL) OR
              (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

        -- ==========================================================================================
        -- 4. Execution Pipeline Matrix - SUB-PILLAR 1: Laboratories & Pathology Panels
        -- ==========================================================================================
        ;WITH CompletedLabPanels AS (
            SELECT 
                lto.OrderGuid,
                lto.CPTCode AS PanelCupsCode,      
                lto.CPTDescription AS PanelDescription,
                lto.PatientVisit,
                lto.Facility AS FacilityId,
                lto.DateTimeEntered AS CompletionDate, 
                YEAR(lto.DateTimeEntered) AS YearOfService,
                ISNULL(amx.Ambity, '02') AS Ambity, 
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                @ResolvedContractGuid AS ResolvedContractGuid,
                @ResolvedManual AS ResolvedManual,
                @ResolvedAdjustmentPct AS ResolvedAdjustmentPct,
                @ResolvedNightCharges AS ResolvedNightCharges,
                ISNULL(lto.AssociatedDiagnosis,'none') As DiagnosisCode,
                ISNULL(lto.NoBill, 0) AS NoBill,
                CASE 
                    WHEN @ResolvedNightCharges = 0 Or Ambity = '02'  OR Ambity = '01' OR ISNULL(lto.Priority,'Routine') <> 'STAT'  THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN DATENAME(weekday, ISNULL(lto.DateTimeUpdated, lto.DateTimeEntered)) = 'Sunday' THEN 4 
                    WHEN DATEPART(hour, ISNULL(lto.DateTimeUpdated, lto.DateTimeEntered)) < 7 THEN 3 
                    WHEN DATEPART(hour, ISNULL(lto.DateTimeUpdated, lto.DateTimeEntered)) > 18 THEN 3
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
                              AND ISNULL(lto.DateTimeUpdated, lto.DateTimeEntered) >= DATEADD(HOUR, -24, s.DateTimePerformed)
                              AND ISNULL(lto.DateTimeUpdated, lto.DateTimeEntered) <= DATEADD(HOUR, 6, s.DateTimePerformed)
                        ) THEN 1 
                        ELSE 0 
                    END AS BIT
                ) AS IsLabAbsorbedByBundle
            FROM ClinicalGeniusEhr.dbo.PatientLabTestOrders lto WITH(NOLOCK)
            LEFT JOIN #ColombianHolidays h 
                ON h.HolidayDate = CAST(ISNULL(lto.DateTimeUpdated, lto.DateTimeEntered) AS DATE)
            OUTER APPLY (
                SELECT TOP 1 DPT.Ambity 
                FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
                INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) 
                    ON DPT.DepartmentGuid = PDT.DepartmentGuid
                WHERE PDT.PatientVisit = lto.PatientVisit 
                  AND lto.DateTimeEntered > PDT.StartDateTime 
                  AND (lto.DateTimeEntered < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
                ORDER BY PDT.StartDateTime DESC
            ) amx
            WHERE lto.PatientVisit = @PatientVisit 
              AND lto.Status = 'Completed'         
              AND lto.Facility = @FacilityId        
              AND ISNULL(lto.ExistingCharge, 0) = 0 
              AND (
                  (@TargetClaimGuid = 'Patient' AND lto.ClaimGuid IS NULL) OR
                  (@TargetClaimGuid <> 'Patient' AND lto.ClaimGuid = @TargetClaimGuid)
              )
        ),
        LabLinesWithTariffs AS (
            SELECT 
                cl.*,
                CASE 
                    WHEN cl.ResolvedManual = 'ISS_2001' THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                    ELSE mvx.SOATValue 
                END AS CatalogValue,
                CASE 
                    WHEN cl.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article
                    ELSE mvx.SOATArticle 
                END AS ArticleGroup,
                TRY_CAST(mvx.SOATValue AS INT) AS SurgeryGroup
            FROM CompletedLabPanels cl
            OUTER APPLY (
                SELECT TOP 1 
                    SOATValue, SOATArticle,
                    ISS2001Value, ISS2001UVR, ISS2001Article
                FROM ClinicalGeniusSupplyChain.dbo.Staging_ManualValues mvl WITH(NOLOCK)
                WHERE mvl.CUPSCode = cl.PanelCupsCode
                  AND mvl.YearOfService = cl.YearOfService
                ORDER BY mvl.RecId DESC
            ) mvx
        ),
        AllMatchingLabExceptions AS (
            SELECT 
                lt.*,
                ce.Ranking AS ExceptionRanking,
                ce.PriceValue AS ExceptionPriceValue,
                ISNULL(ce.PriceModifier, 0.00) AS PriceModifier,
                ce.ExceptionGuid,
                ROW_NUMBER() OVER (
                    PARTITION BY lt.OrderGuid
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC
                ) AS ExceptionPriorityRank
            FROM LabLinesWithTariffs lt
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
                ON ce.ContractGuid = lt.ResolvedContractGuid 
                AND ce.Active = 1 
                AND CAST(lt.CompletionDate AS DATE) >= ce.StartDate 
                AND CAST(lt.CompletionDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
                AND (ce.Ranking <> 1 OR ce.ExceptionType = lt.ArticleGroup)
                AND (ce.Ranking <> 2 OR ce.SurgeryGrp = lt.SurgeryGroup) 
                AND (ce.Ranking NOT IN (3, 4, 5, 6, 7, 8) OR ce.CupsCode = lt.PanelCupsCode) 
                AND (ce.ShiftType = 1 OR ce.ShiftType = lt.RowShiftType) 
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = lt.Ambity)
        ),
        CalculatedLabLines AS (
            SELECT 
                e.*,
                CAST(1 + (e.ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
                CAST(CASE WHEN e.RowShiftType IN (3, 4) THEN 1.25 ELSE 1.00 END AS DECIMAL(10,4)) AS ShiftMultiplier,
                CASE 
                    WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate < '2024-01-01'  THEN 'SMDLV'
                    WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 'UVB'
                    WHEN e.ResolvedManual LIKE 'ISS%' THEN 'UVR' 
                    ELSE 'COP' 
                END AS ValueBasis,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM AllMatchingLabExceptions e
             OUTER APPLY (
                SELECT TOP 1 UnitValue 
                FROM #UnitParameters up 
                WHERE up.ContractType = CASE WHEN e.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up.CalendarYear = e.YearOfService
                  AND up.UnitCategory = CASE WHEN e.CompletionDate >= '2024-01-01' AND e.ResolvedManual = 'SOAT' THEN 'UVB'
                                             WHEN e.CompletionDate < '2024-01-01' AND e.ResolvedManual = 'SOAT'  THEN 'SMDLV'
                                             ELSE 'UVR' END
            ) up
            WHERE e.ExceptionPriorityRank = 1
        ),
        FinalLabLiquidation AS (
            SELECT 
                c.*,
                CAST(
                    CASE 
                        WHEN c.NoBill = 1 THEN 0.00
                        WHEN c.IsLabAbsorbedByBundle = 1 THEN 0.00
                        WHEN c.ExceptionRanking IN (3, 5, 7, 8) THEN c.ExceptionPriceValue * c.ShiftMultiplier
                        ELSE (c.CatalogValue * c.ShiftMultiplier * c.BaseCalculatedValue * c.UnitMonetaryValue)
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
            'Diagnostics' AS TransactionType,     
            f.ResolvedClaimGuid AS ClaimGuid, 
            NULL AS SurgeryGuid, 
            f.ResolvedContractGuid AS ContractGuid, 
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
            ROUND(f.PanelLineNetAmount, -2) AS NetAmount,
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.PanelLineNetAmount * 0.19, -2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.PanelLineNetAmount + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.PanelLineNetAmount * 0.19, -2) 
                    ELSE 0.00 
                END, -2) AS PerItemChargeAmount,
            CASE WHEN f.NoBill = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status]
        FROM FinalLabLiquidation f;

        -- ==========================================================================================
        -- 5. Execution Pipeline Matrix - SUB-PILLAR 2: Diagnostic Imaging Services
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
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                @ResolvedContractGuid AS ResolvedContractGuid,
                @ResolvedManual AS ResolvedManual,
                @ResolvedAdjustmentPct AS ResolvedAdjustmentPct,
                @ResolvedNightCharges AS ResolvedNightCharges,
                ISNULL(img.AssociatedDiagnosis,'none') As DiagnosisCode,
                ISNULL(img.NoBill, 0) AS NoBill,   
                CASE 
                    WHEN @ResolvedNightCharges = 0 OR Ambity = '02' OR Ambity = '01' OR ISNULL(img.Priority,'Routine') <> 'STAT' THEN 2 
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
                              AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) >= DATEADD(HOUR, -24, s.DateTimePerformed)
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
                  AND img.DateTimeEntered > PDT.StartDateTime 
                  AND (img.DateTimeEntered < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
                ORDER BY PDT.StartDateTime DESC
            ) amx
            WHERE img.PatientVisit = @PatientVisit 
              AND img.OrderStatus = 'Completed'     
              AND img.Facility = @FacilityId         
              AND (
                  (@TargetClaimGuid = 'Patient' AND img.ClaimGuid IS NULL) OR
                  (@TargetClaimGuid <> 'Patient' AND img.ClaimGuid = @TargetClaimGuid)
              )
        ),
        ImagingLinesWithTariffs AS (
            SELECT 
                io.*,
                CASE 
                    WHEN io.ResolvedManual = 'ISS_2001' THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                    ELSE mvx.SOATValue 
                END AS CatalogValue,
                CASE 
                    WHEN io.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article
                    ELSE mvx.SOATArticle 
                END AS ArticleGroup,
                TRY_CAST(mvx.SOATValue AS INT) AS SurgeryGroup
            FROM CompletedImagingOrders io
            OUTER APPLY (
                SELECT TOP 1 
                    SOATValue, SOATArticle,
                    ISS2001Value, ISS2001UVR, ISS2001Article
                FROM ClinicalGeniusSupplyChain.dbo.Staging_ManualValues mvl WITH(NOLOCK)
                WHERE mvl.CUPSCode = io.ImagingCupsCode
                  AND mvl.YearOfService = io.YearOfService
                ORDER BY mvl.RecId DESC
            ) mvx
        ),
        AllMatchingImagingExceptions AS (
            SELECT 
                im.*,
                ce.Ranking AS ExceptionRanking,
                ce.PriceValue AS ExceptionPriceValue,
                ISNULL(ce.PriceModifier, 0.00) AS PriceModifier,
                ce.ExceptionGuid,
                ROW_NUMBER() OVER (
                    PARTITION BY im.ImagingOrderGuid
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC
                ) AS ExceptionPriorityRank
            FROM ImagingLinesWithTariffs im
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
                ON ce.ContractGuid = im.ResolvedContractGuid 
                AND ce.Active = 1 
                AND CAST(im.CompletionDate AS DATE) >= ce.StartDate 
                AND CAST(im.CompletionDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
                AND (ce.Ranking <> 1 OR ce.ExceptionType = im.ArticleGroup)
                AND (ce.Ranking <> 2 OR ce.SurgeryGrp = im.SurgeryGroup) 
                AND (ce.Ranking NOT IN (3, 4, 5, 6, 7, 8) OR ce.CupsCode = im.ImagingCupsCode) 
                AND (ce.ShiftType = 1 OR ce.ShiftType = im.RowShiftType) 
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = im.Ambity)
        ),
        CalculatedImagingLines AS (
            SELECT 
                e.*,
                CAST(1 + (e.ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
                CAST(CASE WHEN e.RowShiftType IN (3, 4) THEN 1.25 ELSE 1.00 END AS DECIMAL(10,4)) AS ShiftMultiplier,
                CASE 
                    WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate < '2024-01-01'  THEN 'SMDLV'
                    WHEN e.ResolvedManual = 'SOAT' AND e.CompletionDate >= '2024-01-01' THEN 'UVB'
                    WHEN e.ResolvedManual LIKE 'ISS%' THEN 'UVR' 
                    ELSE 'COP' 
                END AS ValueBasis,
                ROW_NUMBER() OVER (
                    PARTITION BY e.PatientVisit, CAST(e.CompletionDate AS DATE) 
                    ORDER BY e.CatalogValue DESC
                ) AS DailyImageRank,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM AllMatchingImagingExceptions e
            OUTER APPLY (
                SELECT TOP 1 UnitValue 
                FROM #UnitParameters up 
                WHERE up.ContractType = CASE WHEN e.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up.CalendarYear = e.YearOfService
                  AND up.UnitCategory = CASE WHEN e.CompletionDate >= '2024-01-01' AND e.ResolvedManual = 'SOAT' THEN 'UVB'
                                             WHEN e.CompletionDate < '2024-01-01' AND e.ResolvedManual = 'SOAT'  THEN 'SMDLV'
                                             ELSE 'UVR' END
            ) up
            WHERE e.ExceptionPriorityRank = 1
        ),
        FinalImagingLiquidation AS (
            SELECT 
                c.*,
                CAST(
                    CASE 
                        WHEN c.NoBill = 1 THEN 0.00
                        WHEN c.IsImagingAbsorbedByBundle = 1 THEN 0.00
                        WHEN c.ExceptionRanking IN (3, 5, 7, 8) THEN c.ExceptionPriceValue * c.ShiftMultiplier
                        ELSE (c.CatalogValue * c.ShiftMultiplier * c.BaseCalculatedValue * c.UnitMonetaryValue) * 
                            CASE WHEN c.DailyImageRank > 1 THEN 0.75 ELSE 1.00 END -- Multiple Image Discount
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
            'Diagnostics' AS TransactionType,     
            f.ResolvedClaimGuid AS ClaimGuid, 
            NULL AS SurgeryGuid, 
            f.ResolvedContractGuid AS ContractGuid, 
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
            ROUND(f.ImagingLineNetAmount, -2) AS NetAmount,
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.ImagingLineNetAmount * 0.19, -2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.ImagingLineNetAmount + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.ImagingLineNetAmount * 0.19, -2) 
                    ELSE 0.00 
                END, -2) AS PerItemChargeAmount,
            CASE WHEN f.NoBill = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status]
        FROM FinalImagingLiquidation f;

        COMMIT TRANSACTION;
        SELECT 'DIAGNOSTICS LIQUIDATED SUCCESSFULLY' AS ExecutionStatus;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrSeverity INT       = ERROR_SEVERITY(),
                @ErrState INT          = ERROR_STATE();

        RAISERROR (@ErrMsg, @ErrSeverity, @ErrState);
    END CATCH;

    IF OBJECT_ID('tempdb..#ColombianHolidays') IS NOT NULL DROP TABLE #ColombianHolidays;
    IF OBJECT_ID('tempdb..#UnitParameters') IS NOT NULL DROP TABLE #UnitParameters;
END;
GO