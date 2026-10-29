USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  StoredProcedure [odata].[COLLiquidateClaim] ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


ALTER PROCEDURE [odata].[COLLiquidateClaim]
    @PatientVisit    NVARCHAR(50),
    @FacilityId      NVARCHAR(100) = NULL,
    @TargetClaimGuid NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ==========================================================================================
    -- 0. SHARED CONTEXT RESOLUTION (resolved once, used by every module)
    -- ==========================================================================================
    DECLARE @PatientId             NVARCHAR(50),
            @VisitDiagnosis        NVARCHAR(50),
            @ResolvedClaimGuid     NVARCHAR(50),
            @ResolvedContractGuid  NVARCHAR(50),
            @ResolvedManual        VARCHAR(20),
            @ResolvedAdjustmentPct DECIMAL(5,2),
            @ResolvedNightCharges  BIT;

    SELECT TOP 1 @PatientId = PatientId
    FROM ClinicalGeniusEhr.dbo.PatientVisits WITH(NOLOCK)
    WHERE PatientVisitUniqueId = @PatientVisit AND FacilityId = @FacilityId;

    -- (Room Charges) Most recent active diagnosis code for the visit
    SELECT TOP 1 @VisitDiagnosis = prb.ProblemCode 
    FROM ClinicalGeniusEhr.dbo.PatientProblemList prb WITH(NOLOCK) 
    WHERE prb.PatientVisit = @PatientVisit 
      AND prb.ProblemStatus = 'Active' 
    ORDER BY prb.ProblemDateTimeEntered DESC;

    SET @VisitDiagnosis = ISNULL(@VisitDiagnosis, 'none');

    -- Route A: Patient Responsibility
    IF @TargetClaimGuid = 'Patient'
    BEGIN
        SET @ResolvedClaimGuid     = 'Patient'; 
        SET @ResolvedContractGuid  = NULL;
        SET @ResolvedManual        = 'SOAT';
        SET @ResolvedAdjustmentPct = 0.00;
        SET @ResolvedNightCharges  = 0;
    END
    -- Route B: Explicit Payer Claim Targeted
    ELSE 
    BEGIN
        SELECT TOP 1 
            @ResolvedClaimGuid     = pyc.ClaimGuid,
            @ResolvedContractGuid  = isc.ContractGuid,
            @ResolvedManual        = ISNULL(isc.EntityCode, 'SOAT'),
            @ResolvedAdjustmentPct = ISNULL(isc.AdjustmentPct, 0.00),
            @ResolvedNightCharges  = ISNULL(isc.NightCharges, 0)
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
            ON ppy.PatientPayerGuid = pyc.PayerGuid
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsurancePlans isp WITH(NOLOCK) 
            ON isp.PlanGuid = ppy.PayerPlan
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
            ON isc.ContractGuid = isp.ContractGuid
        WHERE pyc.ClaimGuid = @TargetClaimGuid
          AND pyc.Facility = @FacilityId;
    END

    -- (Copay) Context
    DECLARE @PatientFinancialClass   VARCHAR(5)     = 'A',
            @MaxAllowedCopayPerEvent DECIMAL(18,2)  = 99999999.99,
            @PriorVisitLiability     DECIMAL(18,2)  = 0.00,
            @CurrentClaimLiability   DECIMAL(18,2)  = 0.00,
            @AvailableCapSpace       DECIMAL(18,2)  = 0.00,
            @CopayYearOfService      INT;

    -- (Scrubber) Context
    DECLARE @PatientSex VARCHAR(20),
            @AgeInYears INT;


    -- ==========================================================================================
    -- 0.1 SHARED TEMP TABLES (created once)
    -- ==========================================================================================
    IF OBJECT_ID('tempdb..#ColombianHolidays')     IS NOT NULL DROP TABLE #ColombianHolidays;
    IF OBJECT_ID('tempdb..#UnitParameters')        IS NOT NULL DROP TABLE #UnitParameters;
    IF OBJECT_ID('tempdb..#StatutoryCopayLimits')  IS NOT NULL DROP TABLE #StatutoryCopayLimits;
    IF OBJECT_ID('tempdb..#SurgeryContext')        IS NOT NULL DROP TABLE #SurgeryContext;
    IF OBJECT_ID('tempdb..#SurgeryLineItems')      IS NOT NULL DROP TABLE #SurgeryLineItems;

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
        ('2028-12-08'),('2028-12-25');

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

    CREATE TABLE #StatutoryCopayLimits (
        CalendarYear INT, FinancialClass VARCHAR(5), MaxCapPerEvent DECIMAL(18,2)
    );
    INSERT INTO #StatutoryCopayLimits (CalendarYear, FinancialClass, MaxCapPerEvent)
    VALUES
        (2023, 'A', 304583.00), (2023, 'B', 1220455.00), (2023, 'C', 2440909.00), (2023, 'S1', 0.00),
        (2024, 'A', 338900.00), (2024, 'B', 1357600.00), (2024, 'C', 2715200.00), (2024, 'S1', 0.00),
        (2025, 'A', 370000.00), (2025, 'B', 1480000.00), (2025, 'C', 2960000.00), (2025, 'S1', 0.00),
        (2026, 'A', 400000.00), (2026, 'B', 1600000.00), (2026, 'C', 3200000.00), (2026, 'S1', 0.00);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ##########################################################################################
        -- ##  MODULE 1: ROOM CHARGES (Stay)
        -- ##########################################################################################

        -- 1.2 Auto-Assign Unassigned Bed Assignments to Target Claim
        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.PatientBedAssignments WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND ClaimGuid IS NULL;
        END

        -- 1.3 Targeted Staging Clear (Safeguards Invoiced Records)
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Stays'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Stay'
          AND Status = 'Active' 
          AND (
              (@TargetClaimGuid = 'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = 'Patient')) OR
              (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

        -- 1.4 Execution Pipeline Matrix
        ;WITH Tally(n) AS (
            SELECT TOP 1000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
            FROM sys.all_columns a
            CROSS JOIN (SELECT TOP 2 * FROM sys.all_columns) b
        ),
        ExpandedStayDays AS (
            SELECT 
                ba.BedAssignmentGuid AS StayGuid,
                ba.EnteredBy,
                ba.DateTimeEntered,
                ba.PatientVisit,
                r.RoomAndBedNumber,
                r.OpenErpBedId AS BedCategoryCode,   
                @FacilityId AS FacilityId,
                @VisitDiagnosis AS DiagnosisCode,
                CAST(DATEADD(DAY, t.n, ba.DateTimeAssigned) AS DATE) AS StayCalendarDate,
                YEAR(DATEADD(DAY, t.n, ba.DateTimeAssigned)) AS YearOfService,
                ba.DateTimeAssigned,
                ba.DateTimeCheckedOut
            FROM ClinicalGeniusEhr.dbo.PatientBedAssignments ba WITH(NOLOCK)
            INNER JOIN ClinicalGeniusSupplyChain.dbo.FacilityPatientRooms r WITH(NOLOCK)
                ON r.RoomGuid = ba.RoomGuid
            INNER JOIN Tally t ON t.n <= DATEDIFF(DAY, ba.DateTimeAssigned, ISNULL(ba.DateTimeCheckedOut, GETDATE()))
            WHERE ba.PatientVisit = @PatientVisit
              AND ba.Facility = @FacilityId
              AND r.OpenErpBedId IS NOT NULL 
              AND r.OpenErpBedId <> '' 
              AND r.OpenErpBedId <> ' '
              AND (
                  (@TargetClaimGuid = 'Patient' AND ba.ClaimGuid IS NULL) OR
                  (@TargetClaimGuid <> 'Patient' AND ba.ClaimGuid = @TargetClaimGuid)
              )
        ),
        DeduplicatedStayDays AS (
            SELECT 
                StayGuid,
                EnteredBy,
                DateTimeEntered,
                PatientVisit,
                BedCategoryCode,
                RoomAndBedNumber,
                FacilityId,
                DiagnosisCode,
                StayCalendarDate,
                YearOfService
            FROM (
                SELECT *,
                    ROW_NUMBER() OVER (
                        PARTITION BY StayCalendarDate 
                        -- Chronological tie-breaking to prevent same-day double billing
                        ORDER BY DateTimeAssigned DESC, ISNULL(DateTimeCheckedOut, GETDATE()) DESC
                    ) as RowRank
                FROM ExpandedStayDays
            ) ranked
            WHERE RowRank = 1
        ),
        StaysWithTariffBaselines AS (
            SELECT 
                es.*,
                CASE 
                    WHEN ISNULL(@ResolvedManual, 'SOAT') = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN @ResolvedManual = 'ISS_2001'             THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                    ELSE 0.00 
                END AS RoomCatalogUnits,
                CASE 
                    WHEN ISNULL(@ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
                    WHEN @ResolvedManual = 'ISS_2001'             THEN mvx.ISS2001Article
                    ELSE NULL 
                END AS ArticleGroup,
                CAST(
                    CASE 
                        WHEN EXISTS (
                            SELECT 1 FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
                            WHERE s.PatientVisit = es.PatientVisit
                              AND s.Status = 'Completed'
                              AND s.IsBundle = 1
                              AND s.RoomIncluded = 1
                              AND es.StayCalendarDate >= CAST(COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()) AS DATE)
                              AND es.StayCalendarDate <= CAST(DATEADD(DAY, 1, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE())) AS DATE)
                        ) THEN 1 
                        ELSE 0 
                    END AS BIT
                ) AS IsStayAbsorbedByBundle
            FROM DeduplicatedStayDays es
            OUTER APPLY (
                SELECT TOP 1 
                    SOATValue, SOATArticle,
                    ISS2001Value, ISS2001UVR, ISS2001Article
                FROM ClinicalGeniusSupplyChain.dbo.Staging_ManualValues mvl WITH(NOLOCK)
                WHERE mvl.CUPSCode = es.BedCategoryCode
                  AND mvl.YearOfService = es.YearOfService
                ORDER BY mvl.RecId DESC
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
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ColombiaContractExceptions ce WITH(NOLOCK) 
                ON ce.ContractGuid = @ResolvedContractGuid 
                AND ce.Active = 1 
                AND st.StayCalendarDate >= ce.StartDate 
                AND st.StayCalendarDate <= ISNULL(ce.EndDate, '9999-12-31') 
                AND ce.ExceptionType = st.ArticleGroup
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '03') 
        ),
        CalculatedStayDays AS (
            SELECT 
                ex.*,
                CAST(1 + (@ResolvedAdjustmentPct / 100.00) + (ex.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
                CASE 
                    WHEN @ResolvedManual = 'SOAT' AND ex.StayCalendarDate < '2024-01-01'  THEN 'SMDLV'
                    WHEN @ResolvedManual = 'SOAT' AND ex.StayCalendarDate >= '2024-01-01' THEN 'UVB'
                    WHEN @ResolvedManual LIKE 'ISS%'                                      THEN 'UVR' 
                    ELSE 'COP' 
                END AS ValueBasis,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM AllMatchingStayExceptions ex
            OUTER APPLY (
                SELECT TOP 1 UnitValue 
                FROM #UnitParameters up 
                WHERE up.ContractType = CASE WHEN @ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up.CalendarYear = ex.YearOfService
                  AND up.UnitCategory = CASE WHEN ex.StayCalendarDate >= '2024-01-01' AND @ResolvedManual = 'SOAT' THEN 'UVB'
                                             WHEN ex.StayCalendarDate < '2024-01-01'  AND @ResolvedManual = 'SOAT' THEN 'SMDLV'
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
                        WHEN @ResolvedManual LIKE 'ISS%' THEN (ISNULL(c.RoomCatalogUnits, 0.00) * c.BaseCalculatedValue)
                        ELSE (ISNULL(c.RoomCatalogUnits, 0.00) * c.BaseCalculatedValue * c.UnitMonetaryValue)
                    END AS DECIMAL(18,2)
                ) AS DayLineNetAmount
            FROM CalculatedStayDays c
        )
        INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid, 
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
            PerItemChargeAmount, DispensingValue, CodigoVIDA, [Status],TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,CurrentWorkflowStatus
        )
        SELECT 
            @FacilityId, 
            @PatientId, 
            @PatientVisit, 
            'Stay' AS TransactionType,   
            f.StayGuid,      --Added OrderGuid Dan
            @ResolvedClaimGuid, 
            NULL AS SurgeryGuid, 
            @ResolvedContractGuid, 
            f.ExceptionGuid, 
            '03',                --Ambity    
            f.UnitMonetaryValue, 
            'Día de Estancia Hosp: Category Code ' + f.BedCategoryCode, 
            NULL AS SurgicalGroup, 
            NULL AS SurgicalApproach, 
            0 AS SurgicalSequence, 
            2 AS ShiftTypeApplied,             
            0.00 AS SurchargeAmount, 
            f.BedCategoryCode AS CupsCode, 
            NULL AS CUMCode, 
            CAST(f.StayCalendarDate AS DATETIME), 
            GETDATE() AS DateTimeEntered, 
            @ResolvedManual AS RevenueCode, 
            1 AS Quantity,                     
            0.00 AS ItemCost, 
            f.DiagnosisCode AS ItemSnomedCode, 
            f.RoomCatalogUnits AS ItemAlternateCode, 
            f.BaseCalculatedValue AS LocalAmount, 
            1.00 AS USDBasePrice, 
            1.00 AS USDPerItemChargeAmount, 
            f.ValueBasis AS PaymentType, 
            ROUND(f.DayLineNetAmount, 2) AS NetAmount,    
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.DayLineNetAmount * 0.19, 2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.DayLineNetAmount + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.DayLineNetAmount * 0.19, 2) 
                    ELSE 0.00 
                END, 2) AS PerItemChargeAmount, 
            0.00 AS DispensingValue,
            NULL AS CodigoVIDA,
            'Active' AS [Status],
            NEWID(),
            'Día',
            'Hospital Stay',
            NULL,
            'Hospital Stay',
            f.BedCategoryCode,
            NULL,
            NULL,
            f.EnteredBy,
            f.DateTimeEntered,
            CASE WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN 0.19 ELSE 0.00 END, 
            0, --Discount Rate
            f.RoomAndBedNumber,
            f.DayLineNetAmount,
            'Pending Review'
        FROM FinalStayLiquidationLines f;


        -- ##########################################################################################
        -- ##  MODULE 2: DIAGNOSTICS (Labs / Pathology / Imaging)
        -- ##########################################################################################

        -- 2.2 Auto-Assign Unassigned Diagnostics to Target Claim
        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.LabTestOrders WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND Status = 'Completed'
              AND ClaimGuid IS NULL;

            UPDATE ClinicalGeniusEhr.dbo.ImagingOrders WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND OrderStatus = 'Completed'
              AND ClaimGuid IS NULL;
        END

        -- 2.3 Targeted Staging Clear (Safeguards Invoiced Records)
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Diagnostics'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType in ('Laboratory','Imaging')
          AND SurgeryGuid IS NULL
          AND Status = 'Active' 
          AND (
              (@TargetClaimGuid = 'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = 'Patient')) OR
              (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

        -- 2.4 SUB-PILLAR 1: Laboratories & Pathology Panels
        ;WITH CompletedLabPanels AS (
            SELECT 
                lto.OrderGuid,
                lap.CPTCode AS PanelCupsCode,      
                lto.CPTDescription AS PanelDescription,
                lto.PatientVisit,
                lto.Facility AS FacilityId,
                lto.EnteredBy,
                lto.DateTimeOrdered,
                ISNULL(lto.DateTimeDrawn, lto.DateTimeOrdered) AS CompletionDate, 
                YEAR(ISNULL(lto.DateTimeDrawn, lto.DateTimeORdered)) AS YearOfService,
                ISNULL(amx.Ambity, '02') AS Ambity, 
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                @ResolvedContractGuid AS ResolvedContractGuid,
                @ResolvedManual AS ResolvedManual,
                @ResolvedAdjustmentPct AS ResolvedAdjustmentPct,
                @ResolvedNightCharges AS ResolvedNightCharges,
                ISNULL(lto.AssociatedDiagnosis,'none') As DiagnosisCode,
                ISNULL(lto.NoBill, 0) AS NoBill,
                CASE 
                    WHEN @ResolvedNightCharges = 0 Or Ambity = '02'  OR Ambity = '01' OR ISNULL(lto.OrderPriority,'Routine') <> 'STAT'  THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN DATENAME(weekday, ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered)) = 'Sunday' THEN 4 
                    WHEN DATEPART(hour, ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered)) < 7 THEN 3 
                    WHEN DATEPART(hour, ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered)) > 18 THEN 3
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
                              AND ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered) >= DATEADD(HOUR, -24, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()))
                              AND ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered) <= DATEADD(HOUR, 6, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()))
                        ) THEN 1 
                        ELSE 0 
                    END AS BIT
                ) AS IsLabAbsorbedByBundle
            FROM ClinicalGeniusEhr.dbo.LabTestOrders lto WITH(NOLOCK)
            INNER JOIN ClinicalGeniusEhr.dbo.LabPanelsByFacility lap WITH(NOLOCK)
                ON lap.LabPanelGuid = lto.CPTCode
            LEFT JOIN #ColombianHolidays h 
                ON h.HolidayDate = CAST(ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered) AS DATE)
            OUTER APPLY (
                SELECT TOP 1 DPT.Ambity 
                FROM ClinicalGeniusEHR.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
                INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) 
                    ON DPT.DepartmentGuid = PDT.DepartmentGuid
                WHERE PDT.PatientVisit = lto.PatientVisit 
                  AND lto.DateTimeOrdered > PDT.StartDateTime 
                  AND (lto.DateTimeOrdered < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
                ORDER BY PDT.StartDateTime DESC
            ) amx
            WHERE lto.PatientVisit = @PatientVisit 
              AND lto.Status = 'Completed'         
              AND lto.Facility = @FacilityId        
              AND ((@TargetClaimGuid = 'Patient' AND lto.ClaimGuid IS NULL) OR
                  (@TargetClaimGuid <> 'Patient' AND lto.ClaimGuid = @TargetClaimGuid)
              )
        ),
        LabLinesWithTariffs AS (
            SELECT 
                cl.*,
                -- Add explicit SOAT routing and TRY_CAST for fractional precision
                CASE 
                    WHEN cl.ResolvedManual = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN cl.ResolvedManual = 'ISS_2001' THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                    ELSE 0.00 
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
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ColombiaContractExceptions ce WITH(NOLOCK) 
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
                        -- Insert the ISNULL here to prevent NULL propagation
                        ELSE (ISNULL(c.CatalogValue, 0.00) * c.ShiftMultiplier * c.BaseCalculatedValue * c.UnitMonetaryValue)
                    END AS DECIMAL(18,2)
                ) AS PanelLineNetAmount
            FROM CalculatedLabLines c
        )
        INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid, 
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
            PerItemChargeAmount, DispensingValue, CodigoVIDA, [Status],TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,CurrentWorkflowStatus
        )
        SELECT 
            @FacilityId, 
            @PatientId, 
            @PatientVisit, 
            'Laboratory' AS TransactionType, -- Changed Diagnostics to Laboratory Dan
            f.OrderGuid,  --Added OrderGuid Dan
            f.ResolvedClaimGuid AS ClaimGuid, 
            NULL AS SurgeryGuid, 
            f.ResolvedContractGuid AS ContractGuid, 
            f.ExceptionGuid, 
            f.Ambity, 
            f.UnitMonetaryValue, 
            'Examen de Laboratorio/Patología: ' + f.PanelDescription, 
            NULL AS SurgicalGroup, 
            NULL AS SurgicalApproach, 
            0 AS SurgicalSequence, 
            f.RowShiftType AS ShiftTypeApplied, 
            0.00 AS SurchargeAmount, 
            f.PanelCupsCode AS CupsCode, 
            NULL AS CUMCode, 
            f.CompletionDate, 
            GETDATE() AS DateTimeEntered, 
            f.ResolvedManual AS RevenueCode, 
            1 AS Quantity, 
            0.00 AS ItemCost, 
            f.DiagnosisCode AS ItemSnomedCode,     
            NULL AS ItemAlternateCode, 
            f.BaseCalculatedValue AS LocalAmount, 
            1.00 AS USDBasePrice, 
            1.00 AS USDPerItemChargeAmount, 
            f.ValueBasis AS PaymentType, 
            ROUND(f.PanelLineNetAmount, 2) AS NetAmount,
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.PanelLineNetAmount * 0.19, 2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.PanelLineNetAmount + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.PanelLineNetAmount * 0.19, 2) 
                    ELSE 0.00 
                END, 2) AS PerItemChargeAmount,
            0.00 AS DispensingValue,
            NULL AS CodigoVIDA,
            CASE WHEN f.NoBill = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status],
            NEWID(),
            'Laboratorio',
            NULL,
            NULL, --ItemMasterGuid??,
            f.PanelDescription,
            f.PanelCupsCode,
            NULL, --Type??
            NULL, --Category??,
            f.EnteredBy,
            f.DateTimeOrdered,
            CASE WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN 0.19 ELSE 0.00 END, 
            0,
            f.PanelDescription,
            f.PanelLineNetAmount,
            'Pending Review'
        FROM FinalLabLiquidation f;

        -- 2.5 SUB-PILLAR 2: Diagnostic Imaging Services
        ;WITH CompletedImagingOrders AS (
            SELECT 
                img.ImagingOrderGuid,
                ioi.CPTCode AS ImagingCupsCode,       
                img.ImagingOrderDescription AS ImagingDescription,
                img.PatientVisit,
                img.EnteredBy,
                img.DateTimeEntered,
                img.Facility AS FacilityId,
                ISNULL(img.DateTimeUpdated, img.DateTimeEntered) AS CompletionDate, 
                YEAR(ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) AS YearOfService,
                ISNULL(amx.Ambity, '02') AS Ambity, 
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                @ResolvedContractGuid AS ResolvedContractGuid,
                @ResolvedManual AS ResolvedManual,
                @ResolvedAdjustmentPct AS ResolvedAdjustmentPct,
                @ResolvedNightCharges AS ResolvedNightCharges,
                ISNULL(ppl.ProblemCode,'none') As DiagnosisCode,
                ISNULL(img.NoBill, 0) AS NoBill,   
                CASE 
                    WHEN @ResolvedNightCharges = 0 OR Ambity = '02' OR Ambity = '01' OR ISNULL(img.OrderPriority,'Routine') <> 'STAT' THEN 2 
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
                              AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) >= DATEADD(HOUR, -24, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()))
                              AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) <= DATEADD(HOUR, 6, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()))
                        ) THEN 1 
                        ELSE 0 
                    END AS BIT
                ) AS IsImagingAbsorbedByBundle
            FROM ClinicalGeniusEhr.dbo.ImagingOrders img WITH(NOLOCK)
            INNER JOIN ClinicalGeniusEhr.dbo.ImagingOrderItems ioi WITH(NOLOCK)
                ON ioi.ImageOrderGuid = img.ImageOrderItemGuid
            INNER JOIN ClinicalGeniusEhr.dbo.PatientProblemList ppl WITH(NOLOCK)
                ON ppl.ProblemGuid = img.IndicationGuid
            LEFT JOIN #ColombianHolidays h 
                ON h.HolidayDate = CAST(ISNULL(img.DateTimeUpdated, img.DateTimeEntered) AS DATE)
            OUTER APPLY (
                SELECT TOP 1 DPT.Ambity 
                FROM ClinicalGeniusEHR.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
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
                -- FIX: Explicit SOAT routing, decimal casting for fractional tariffs, and 0.00 fallback
                CASE 
                    WHEN io.ResolvedManual = 'SOAT'     THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN io.ResolvedManual = 'ISS_2001' THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                    ELSE 0.00 
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
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ColombiaContractExceptions ce WITH(NOLOCK) 
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
                        -- FIX: ISNULL applied to CatalogValue to halt NULL propagation
                        ELSE (ISNULL(c.CatalogValue, 0.00) * c.ShiftMultiplier * c.BaseCalculatedValue * c.UnitMonetaryValue) * 
                            CASE WHEN c.DailyImageRank > 1 THEN 0.75 ELSE 1.00 END -- Multiple Image Discount
                    END AS DECIMAL(18,2)
                ) AS ImagingLineNetAmount
            FROM CalculatedImagingLines c
        )
        INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid, 
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
            PerItemChargeAmount, DispensingValue, CodigoVIDA, [Status],TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,CurrentWorkflowStatus
        )
        SELECT 
            @FacilityId, 
            @PatientId, 
            @PatientVisit, 
            'Imaging' AS TransactionType,  -- Changed Diagnostics to Imaging
            f.ImagingOrderGuid,   --Added OrderGuid Dan
            f.ResolvedClaimGuid AS ClaimGuid, 
            NULL AS SurgeryGuid, 
            f.ResolvedContractGuid AS ContractGuid, 
            f.ExceptionGuid, 
            f.Ambity, 
            f.UnitMonetaryValue, 
            'Procedimiento de Imagenología: ' + f.ImagingDescription, 
            NULL AS SurgicalGroup, 
            NULL AS SurgicalApproach, 
            0 AS SurgicalSequence, 
            f.RowShiftType AS ShiftTypeApplied, 
            0.00 AS SurchargeAmount, 
            f.ImagingCupsCode AS CupsCode,       
            NULL AS CUMCode, 
            f.CompletionDate, 
            GETDATE() AS DateTimeEntered, 
            f.ResolvedManual AS RevenueCode, 
            1 AS Quantity, 
            0.00 AS ItemCost, 
            f.DiagnosisCode AS ItemSnomedCode, 
            NULL AS ItemAlternateCode, 
            f.BaseCalculatedValue AS LocalAmount, 
            1.00 AS USDBasePrice, 
            1.00 AS USDPerItemChargeAmount, 
            f.ValueBasis AS PaymentType, 
            ROUND(f.ImagingLineNetAmount, 2) AS NetAmount,
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.ImagingLineNetAmount * 0.19, 2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.ImagingLineNetAmount + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.ImagingLineNetAmount * 0.19, 2) 
                    ELSE 0.00 
                END, 2) AS PerItemChargeAmount,
            0.00 AS DispensingValue,
            NULL AS CodigoVIDA,
            CASE WHEN f.NoBill = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status],
            NEWID(),
            'Imagen',
            NULL,
            NULL, --ItemMasterGuid??,
            f.ImagingDescription,
            f.ImagingCupsCode,
            NULL, --Type??
            NULL, --Category??,
            f.EnteredBy,
            f.DateTimeEntered,
            CASE WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN 0.19 ELSE 0.00 END, 
            0,
            f.ImagingDescription,
            f.ImagingLineNetAmount,
            'Pending Review'
        FROM FinalImagingLiquidation f;


        -- ##########################################################################################
        -- ##  MODULE 3: MEDICATIONS
        -- ##########################################################################################

        -- 3.2 Auto-Assign Unassigned Medications to Target Claim
        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.MedicationAdministrationSchedule WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND Status = 'Completed'
              AND ClaimGuid IS NULL;
        END

        -- 3.3 Targeted Staging Clear (Safeguards Invoiced Records)
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Medications'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Medication'
          AND Status = 'Active' 
          AND ((@TargetClaimGuid = 'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = 'Patient')) OR
              (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

        -- 3.4 Execution Pipeline Matrix
        ;WITH ActiveMedicationList AS (
            SELECT 
                mar.MedSchedGuid,
                mar.PatientId, 
                mar.PatientVisit, 
                mar.AdministeredBy,
                itm.ItemNumber AS MedicationCode,
                itm.ItemMasterGuid,
                itm.ItemName,
                itm.Cost,
                itm.Type,
                itm.Category,
                itm.ItemDescription,
                mar.MedicationName, 
                mar.ActualDoseGiven, 
                mar.QuantityUnit, 
                mar.Facility,
                ISNULL(amx.Ambity, '01') AS Ambity, 
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                ISNULL(mar.NoBill, 0) AS NoBill,
                ISNULL(pmd.AssociatedDiagnosisICDN, 'none') AS DiagnosisCode,
                ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) AS TargetDate,
                YEAR(ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) AS YearOfService,
                CAST(ISNULL(itm.BasePrice, 0.00) AS DECIMAL(18,2)) AS FormularyBasePrice,
                CAST(ISNULL(itm.Cost, 0.00) AS DECIMAL(18,2)) AS FormularyUnitCost,
                CAST(
                    CASE 
                        WHEN s.IsBundle = 1 AND s.MedicationIncluded = 1 THEN 1 
                        ELSE 0 
                    END AS BIT
                ) AS IsBundledInPackage,
                s.SurgeryGuid,
                CASE 
                    WHEN @ResolvedNightCharges = 0 OR ISNULL(amx.Ambity, '01') IN ('01', '02') THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN DATENAME(weekday, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) = 'Sunday' THEN 4 
                    WHEN DATEPART(hour, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) < 7 THEN 3 
                    WHEN DATEPART(hour, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) > 18 THEN 3
                    ELSE 2 
                END AS RowShiftType
            FROM ClinicalGeniusEhr.dbo.MedicationAdministrationSchedule mar WITH(NOLOCK)
            INNER JOIN ClinicalGeniusEhr.dbo.PatientMeds pmd WITH(NOLOCK)
                ON pmd.MedsGuid = mar.MedOrderId
            INNER JOIN ClinicalGeniusSupplyChain.dbo.ItemMaster itm WITH(NOLOCK) 
                ON itm.ItemMasterGuid = pmd.ItemGuid
            LEFT JOIN #ColombianHolidays h 
                ON h.HolidayDate = CAST(ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) AS DATE)
            OUTER APPLY (
                SELECT TOP 1 DPT.Ambity 
                FROM ClinicalGeniusEHR.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
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
                AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) >= DATEADD(HOUR, -24, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()))
                AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) <= DATEADD(HOUR, 6, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()))
            WHERE mar.PatientVisit = @PatientVisit
              AND mar.Status = 'Completed'
              AND mar.Facility = @FacilityId
              AND mar.ActualDoseGiven > 0
              AND (
                  (@TargetClaimGuid = 'Patient' AND mar.ClaimGuid IS NULL) OR
                  (@TargetClaimGuid <> 'Patient' AND mar.ClaimGuid = @TargetClaimGuid)
              )
        ),
        AllMatchingMedicationExceptions AS (
            SELECT 
                m.*,
                ce.Ranking AS ExceptionRanking,
                ce.PriceValue AS ExceptionPriceValue,
                ISNULL(ce.PriceModifier, 0.00) AS PriceModifier, 
                ce.ExceptionGuid,
                ROW_NUMBER() OVER (
                    PARTITION BY m.PatientVisit, m.MedicationCode, m.TargetDate
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC 
                ) AS ExceptionPriorityRank
            FROM ActiveMedicationList m
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ColombiaContractExceptions ce WITH(NOLOCK) 
                ON ce.ContractGuid = @ResolvedContractGuid 
                AND ce.Active = 1 
                AND CAST(m.TargetDate AS DATE) >= ce.StartDate 
                AND CAST(m.TargetDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
                AND (ce.Ranking <> 8 OR ce.CUPSCode = m.MedicationCode)
                AND (ce.ShiftType = 1 OR ce.ShiftType = m.RowShiftType) 
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = m.Ambity) 
        ),
        CalculatedMedicationLines AS (
            SELECT 
                e.*,
                CAST(1 + (@ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
                CAST(
                    CASE 
                        WHEN e.NoBill = 1 THEN 0.00
                        WHEN e.IsBundledInPackage = 1 THEN 0.00
                        WHEN e.ExceptionRanking IN (3, 5, 7, 8) THEN (e.ActualDoseGiven * e.ExceptionPriceValue)
                        ELSE (e.ActualDoseGiven * e.FormularyBasePrice) * CAST(1 + (@ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4))
                    END AS DECIMAL(18,2)
                ) AS MedicationLineTotal,
                0.00 AS DispensingMarkup -- Default dispensing fee markup isolated per Res 948
            FROM AllMatchingMedicationExceptions e
            WHERE e.ExceptionPriorityRank = 1
        )
        INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid, 
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
            PerItemChargeAmount, DispensingValue, CodigoVIDA, [Status],TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,CurrentWorkflowStatus
        )
        SELECT 
            @FacilityId, 
            @PatientId, 
            @PatientVisit, 
            'Medication' AS TransactionType,
            f.MedSchedGuid,       --Added OrderGuid Dan
            f.ResolvedClaimGuid AS ClaimGuid, 
            f.SurgeryGuid,                         
            @ResolvedContractGuid, 
            f.ExceptionGuid, 
            ISNULL(f.Ambity, '02') AS Ambity,             
            f.FormularyBasePrice AS BaseUnitValue, 
            f.MedicationName AS SurgicalComponent, 
            NULL AS SurgicalGroup,                               
            NULL AS SurgicalApproach,                               
            0 AS SurgicalSequence,                                  
            f.RowShiftType AS ShiftTypeApplied,  
            0.00 AS SurchargeAmount,                               
            f.MedicationCode AS CupsCode,          
            f.MedicationCode AS CUMCode,           
            f.TargetDate AS ExternalProcessedDateTime, 
            GETDATE() AS DateTimeEntered,                          
            @ResolvedManual AS RevenueCode,                            
            f.ActualDoseGiven AS Quantity,         
            f.FormularyUnitCost AS ItemCost,       
            f.DiagnosisCode AS ItemSnomedCode,                               
            f.QuantityUnit AS ItemAlternateCode,   
            f.BaseCalculatedValue AS LocalAmount,  
            1.00 AS USDBasePrice,                               
            1.00 AS USDPerItemChargeAmount,                               
            'COP' AS PaymentType,                              
            ROUND(f.MedicationLineTotal, 2) AS NetAmount,    
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.MedicationLineTotal * 0.19, 2) 
                ELSE 0.00 
            END AS TaxAmount,                               
            0.00 AS DiscountAmount,                               
            ROUND(f.MedicationLineTotal + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.MedicationLineTotal * 0.19, 2) 
                    ELSE 0.00 
                END, 2) AS PerItemChargeAmount, 
            ROUND(f.DispensingMarkup, 2) AS DispensingValue,
            NULL AS CodigoVIDA,
            CASE WHEN f.NoBill = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status],
            NEWID(),
            f.QuantityUnit,
            NULL,
            f.ItemMasterGuid,
            f.MedicationName,
            f.MedicationCode,
            f.Type,
            f.Category,
            f.AdministeredBy,
            f.TargetDate,
            CASE WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN 0.19 ELSE 0.00 END, 
            0, --Discount rate
            f.MedicationName,
            f.MedicationLineTotal,
            'Pending Review'
        FROM CalculatedMedicationLines f;


        -- ##########################################################################################
        -- ##  MODULE 4: PROCEDURES
        -- ##########################################################################################

        -- 4.2 Auto-Assign Unassigned Procedures to Target Claim
        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.PatientProcedures WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND ProcedureStatus = 'Active'
              AND ClaimGuid IS NULL;
        END

        -- 4.3 Targeted Staging Clear (Safeguards Invoiced Records & Prevents Cross-Claim Collisions)
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Procedures'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Procedure'
          AND SurgeryGuid IS NULL
          AND Status = 'Active' 
          AND (
              (@TargetClaimGuid = 'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = 'Patient')) OR
              (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
          );
        -- 4.4 Execution Pipeline Matrix
        ;WITH ProcedureList AS (
            SELECT 
                pp.ProcedureGuid, 
                pp.PatientVisit,
                ppa.RVSCode as ProcedureCode, 
                pp.ProcedureDescription, 
                pp.ProcedureObjective,
                pp.LaterialityCode, 
                pp.ServiceGroup,
                pp.EnteredBy,
                pp.DateTimeEntered,
                itm.ItemMasterGuid,
                itm.ItemName,
                itm.ItemNumber,
                itm.Cost,
                itm.Type,
                itm.Category,
                itm.ItemDescription,
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                @ResolvedContractGuid AS ResolvedContractGuid,
                @ResolvedManual AS ResolvedManual,
                @ResolvedAdjustmentPct AS ResolvedAdjustmentPct,
                @ResolvedNightCharges AS ResolvedNightCharges,
                ISNULL(ppl.ProblemCode, 'none') AS DiagnosisCode,
                ISNULL(pp.NoBill, 0) AS IsUnbillable,
                ISNULL(amx.Ambity, '01') AS Ambity, 
                
                -- Dynamic Catalog Value resolution routing through resolved manual
                CASE 
                    WHEN @ResolvedManual = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN @ResolvedManual = 'ISS_2001' THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                    ELSE 0.00 
                END AS CatalogValue,

                -- Surgery Group mapping
                CASE 
                    WHEN @ResolvedManual = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS INT) 
                    WHEN @ResolvedManual = 'ISS_2001' THEN mvx.ISS2001UVR
                    ELSE NULL 
                END AS SurgeryGroup,

                -- Article mapping
                CASE 
                    WHEN @ResolvedManual = 'SOAT' THEN mvx.SOATArticle 
                    WHEN @ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article
                    ELSE NULL 
                END AS ArticleGroup,

                ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS TargetDate,
                YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) AS YearOfService,
                CASE 
                    WHEN @ResolvedNightCharges = 0 OR ISNULL(amx.Ambity, '01') IN ('01', '02') OR ISNULL(pp.ProcedurePriority, 'Routine') <> 'STAT' THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN DATENAME(weekday, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) = 'Sunday' THEN 4 
                    WHEN DATEPART(hour, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) < 7 THEN 3 
                    WHEN DATEPART(hour, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) > 18 THEN 3
                    ELSE 2 
                END AS RowShiftType,
                CAST(
                    CASE 
                        WHEN EXISTS (
                            SELECT 1 FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
                            WHERE s.PatientVisit = pp.PatientVisit
                              AND s.Status = 'Completed'
                              AND s.IsBundle = 1
                              AND s.MaterialIncluded = 1 
                              AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) >= DATEADD(HOUR, -24, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()))
                              AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) <= DATEADD(HOUR, 6, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()))
                        ) THEN 1 
                        ELSE 0 
                    END AS BIT
                ) AS IsProcedureAbsorbedByBundle
            FROM ClinicalGeniusEhr.dbo.PatientProcedures pp WITH(NOLOCK)
            INNER JOIN ClinicalGeniusEHR.dbo.PatientProcedureAdministration ppa WITH(NOLOCK)
                ON ppa.ProcedureGuid = pp.ProcedureCode
            INNER JOIN ClinicalGeniusEhr.dbo.PatientProblemList ppl WITH(NOLOCK)
                ON ppl.ProblemGuid = pp.IndicationGuid
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ItemMaster itm WITH(NOLOCK) 
                ON itm.ItemMasterGuid = pp.ProcedureCode
            LEFT JOIN #ColombianHolidays h 
                ON h.HolidayDate = CAST(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS DATE)
            OUTER APPLY (
                SELECT TOP 1 DPT.Ambity 
                FROM ClinicalGeniusEHR.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
                INNER JOIN ClinicalGeniusSupplyChain.dbo.Departments DPT WITH(NOLOCK) 
                    ON DPT.DepartmentGuid = PDT.DepartmentGuid
                WHERE PDT.PatientVisit = @PatientVisit 
                  AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) > PDT.StartDateTime 
                  AND (ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) < PDT.StopDateTime OR PDT.StopDateTime IS NULL)
                ORDER BY PDT.StartDateTime DESC
            ) amx
            OUTER APPLY (
                SELECT TOP 1 
                    SOATValue, SOATArticle,
                    ISS2001Value, ISS2001UVR, ISS2001Article
                FROM ClinicalGeniusSupplyChain.dbo.Staging_ManualValues mvl WITH(NOLOCK)
                WHERE mvl.CUPSCode = ppa.RVSCode 
                  AND mvl.YearOfService = YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered))
                ORDER BY mvl.RecId DESC
            ) mvx
            WHERE pp.PatientVisit = @PatientVisit 
              AND pp.ProcedureStatus = 'Active'
              AND pp.Facility = @FacilityId
              -- Scoped strictly to target claim (unassigned items are now claimed if running for an insurer)
              AND (
                  (@TargetClaimGuid = 'Patient' AND pp.ClaimGuid IS NULL) OR
                  (@TargetClaimGuid <> 'Patient' AND pp.ClaimGuid = @TargetClaimGuid)
              )
        ),
        AllMatchingProcedureExceptions AS (
            SELECT 
                opl.*,
                ce.Ranking AS ExceptionRanking,
                ce.PriceModifier AS ExceptionPriceModifier, 
                ce.PriceValue AS ExceptionPriceValue,
                ce.ExceptionGuid,
                ROW_NUMBER() OVER (
                    PARTITION BY opl.ProcedureGuid
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC 
                ) AS ExceptionPriorityRank
            FROM ProcedureList opl
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ColombiaContractExceptions ce WITH(NOLOCK) 
                ON ce.ContractGuid = opl.ResolvedContractGuid 
                AND ce.Active = 1 
                AND CAST(opl.TargetDate AS DATE) >= ce.StartDate 
                AND CAST(opl.TargetDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31') 
                AND (ce.Ranking <> 1 OR ce.ExceptionType = opl.ArticleGroup)
                AND (ce.Ranking <> 2 OR ce.SurgeryGrp = opl.SurgeryGroup) 
                AND (ce.Ranking NOT IN (3, 4, 5, 6, 7, 8) OR ce.CupsCode = opl.ProcedureCode) 
                AND (ce.ShiftType = 1 OR ce.ShiftType = opl.RowShiftType) 
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = opl.ServiceGroup)
        ),
        AppliedExceptions AS ( 
            SELECT 
                apx.*,
                ISNULL(ExceptionPriceModifier, 0.00) AS PriceModifier,
                ISNULL(ExceptionPriceValue, 0.00) AS PriceValue
            FROM AllMatchingProcedureExceptions apx
            WHERE ExceptionPriorityRank = 1 
        ),
        BaseUnits AS (
            SELECT 
                pe.*,
                CAST(CASE WHEN pe.IsUnbillable = 1 THEN 0.00 ELSE (1 + (pe.ResolvedAdjustmentPct / 100.00) + (pe.PriceModifier / 100.00)) END AS DECIMAL(10,4)) AS BaseCalculatedValue,
                CAST(ISNULL(pe.CatalogValue, 0.00) AS DECIMAL(18,2)) AS RawCatalogUnits
            FROM AppliedExceptions pe 
        ),
        FinalShiftAdjustments AS (
            SELECT 
                b.*,
                CAST(CASE WHEN b.RowShiftType IN (3, 4) THEN 1.25 ELSE 1.00 END AS DECIMAL(10,4)) AS ShiftMultiplier,
                CASE 
                    WHEN b.ResolvedManual = 'SOAT' AND b.TargetDate < '2024-01-01'  THEN 'SMDLV'
                    WHEN b.ResolvedManual = 'SOAT' AND b.TargetDate >= '2024-01-01' THEN 'UVB'
                    WHEN b.ResolvedManual LIKE 'ISS%'                               THEN 'UVR'
                    ELSE 'COP' 
                END AS ValueBasis,
                ROW_NUMBER() OVER (
                    PARTITION BY b.PatientVisit, CAST(b.TargetDate AS DATE) 
                    ORDER BY b.RawCatalogUnits DESC
                ) AS DailyProcedureRank,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM BaseUnits b
            OUTER APPLY (
                SELECT TOP 1 UnitValue 
                FROM #UnitParameters up 
                WHERE up.ContractType = CASE WHEN b.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up.CalendarYear = b.YearOfService
                  AND up.UnitCategory = CASE WHEN b.TargetDate >= '2024-01-01' AND b.ResolvedManual = 'SOAT' THEN 'UVB'
                                             WHEN b.TargetDate < '2024-01-01'  AND b.ResolvedManual = 'SOAT'  THEN 'SMDLV'
                                             ELSE 'UVR' END
            ) up
        ),
        CalculatedLines AS (
            SELECT 
                o.*,
                CAST(
                    CASE 
                        WHEN o.IsUnbillable = 1 THEN 0.00
                        WHEN o.IsProcedureAbsorbedByBundle = 1 THEN 0.00
                        WHEN o.ExceptionRanking IN (3, 5, 7, 8) THEN o.PriceValue * o.ShiftMultiplier
                        WHEN o.ResolvedManual = 'ISS_2001' AND o.RawCatalogUnits > 3000 THEN 
                             o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue * CASE WHEN o.DailyProcedureRank > 1 THEN 0.50 ELSE 1.00 END
                        ELSE (o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue * o.UnitMonetaryValue) * 
                             CASE WHEN o.DailyProcedureRank > 1 THEN 0.50 ELSE 1.00 END
                    END AS DECIMAL(18,2)
                ) AS LineTotal
            FROM FinalShiftAdjustments o
        )
        INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid, 
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
            PerItemChargeAmount, DispensingValue, CodigoVIDA, [Status], TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,CurrentWorkflowStatus
        )
        SELECT 
            @FacilityId, 
            @PatientId, 
            @PatientVisit, 
            'Procedure' AS TransactionType,  
            f.ProcedureGuid,    --Added OrderGuid Dan
            f.ResolvedClaimGuid AS ClaimGuid,   
            NULL AS SurgeryGuid,                
            f.ResolvedContractGuid AS ContractGuid, 
            f.ExceptionGuid, 
            ISNULL(f.Ambity, '01') AS Ambity,    
            f.UnitMonetaryValue, 
            f.ProcedureDescription, 
            NULL AS SurgicalGroup,               
            NULL AS SurgicalApproach,            
            0 AS SurgicalSequence,                   
            f.RowShiftType AS ShiftTypeApplied,  
            0.00 AS SurchargeAmount,             
            f.ProcedureCode, 
            NULL AS CUMCode,                     
            f.TargetDate, 
            GETDATE() AS DateTimeEntered,        
            f.ResolvedManual AS RevenueCode,              
            1 AS Quantity,                       
            1 AS ItemCost,                       
            f.DiagnosisCode AS ItemSnomedCode, 
            f.RawCatalogUnits AS ItemAlternateCode, 
            f.BaseCalculatedValue AS LocalAmount, 
            1.00 AS USDBasePrice,                
            f.ShiftMultiplier AS USDPerItemChargeAmount, 
            f.ValueBasis AS PaymentType, 
            ROUND(f.LineTotal, 2) AS NetAmount,  
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.LineTotal * 0.19, 2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.LineTotal + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.LineTotal * 0.19, 2) 
                    ELSE 0.00 
                END, 2) AS PerItemChargeAmount, 
            0.00 AS DispensingValue,
            NULL AS CodigoVIDA,
            CASE WHEN f.IsUnbillable = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status],
            NEWID(),
            'Unidad',
            f.ProcedureObjective,
            f.ItemMasterGuid,
            f.ProcedureDescription,
            f.ItemNumber,       /* <--- CHANGED FROM f.ProcedureCode */
            f.Type,
            f.Category,
            f.EnteredBy,
            f.DateTimeEntered,
            CASE WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN 0.19 ELSE 0.00 END, 
            0,
            f.ProcedureDescription,
            f.LineTotal,
            'Pending Review'
        FROM CalculatedLines f;


        -- ##########################################################################################
        -- ##  MODULE 5: SURGERIES
        -- ##########################################################################################

        -- 5.2 Auto-Assign Unassigned Surgeries to Target Claim
        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.ScheduledSurgeries WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND Status = 'Completed'
              AND ClaimGuid IS NULL;
        END

       -- 5.3 Targeted Staging Clear (Safeguards Invoiced Records)
        UPDATE pt
        SET pt.Status = 'Canceled',
            pt.DateTimeLastUpdated = GETDATE(),
            pt.LastUpdatedBy = 'PricingEngine_Surgeries'
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(ROWLOCK, UPDLOCK)
        LEFT JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK) 
            ON s.SurgeryGuid = pt.SurgeryGuid
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Facility = @FacilityId
          AND pt.TransactionType IN ('Surgery', 'RoomRights', 'Supplies', 'Honorary', 'BundleMaster', 'Materials')
          AND pt.Status = 'Active' 
          -- ULTIMATE LOCK: Never cancel or touch rows already batched for DIAN
          AND pt.DIANInvoiceBatchId IS NULL 
          AND (
              -- Cancel all standard lines to recalculate them normally
              pt.TransactionType <> 'Honorary' 
              -- Only cancel Honorary fees if they are completely untouched
              OR (pt.TransactionType = 'Honorary' AND ISNULL(pt.CurrentWorkflowStatus, 'Pending Review') = 'Pending Review')
              -- Always cancel if the surgery was marked NoBill
              OR ISNULL(s.NoBill, 0) = 1 
          )
          AND (
              (@TargetClaimGuid = 'Patient' AND (pt.ClaimGuid IS NULL OR pt.ClaimGuid = 'Patient')) OR
              (@TargetClaimGuid <> 'Patient' AND pt.ClaimGuid = @TargetClaimGuid)
          );

        -- 5.4a Surgery Context
        -- [FIX]: Wrapper applied to cascade through available dates (Performed -> Completed -> Scheduled -> GETDATE)
        --        This gracefully handles unlogged surgery timestamps, ensuring valid SOAT year matches and transaction dates.
        SELECT 
            s.SurgeryGuid,
            COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, GETDATE()) AS DateTimePerformed,
            CAST(ISNULL(s.IsBundle, 0) AS BIT) AS IsBundle,
            s.BundleDescription,
            CAST(ISNULL(s.BundlePrice, 0.00) AS DECIMAL(18,2)) AS BundlePrice,
            CAST(ISNULL(s.SurgeonIncluded, 0) AS BIT) AS SurgeonIncluded,
            CAST(ISNULL(s.AnesthesiologistIncluded, 0) AS BIT) AS AnesthesiologistIncluded,
            CAST(ISNULL(s.AssistantIncluded, 0) AS BIT) AS AssistantIncluded,
            CAST(ISNULL(s.RoomIncluded, 0) AS BIT) AS RoomIncluded,
            CAST(ISNULL(s.MaterialIncluded, 0) AS BIT) AS MaterialIncluded,
            CAST(ISNULL(s.MedicationIncluded, 0) AS BIT) AS MedicationIncluded,
            ISNULL(s.ClaimGuid, @ResolvedClaimGuid) AS ResolvedClaimGuid,
            ISNULL(contract_info.ContractGuid, @ResolvedContractGuid) AS ResolvedContractGuid,
            ISNULL(contract_info.EntityCode, @ResolvedManual) AS ResolvedManual,
            ISNULL(contract_info.AdjustmentPct, @ResolvedAdjustmentPct) AS ResolvedAdjustmentPct,
            ISNULL(contract_info.NightCharges, @ResolvedNightCharges) AS ResolvedNightCharges,
            ISNULL(s.ConfirmedDiagnosisCode, 'none') AS DiagnosisCode,
            ISNULL(s.Priority, 'Electiva') AS Priority
        INTO #SurgeryContext
        FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK)
        OUTER APPLY (
            SELECT TOP 1 
                isc_s.ContractGuid,
                isc_s.EntityCode,
                isc_s.AdjustmentPct,
                isc_s.NightCharges
            FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc_s WITH(NOLOCK)
            INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy_s WITH(NOLOCK) 
                ON ppy_s.PatientPayerGuid = pyc_s.PayerGuid
            INNER JOIN ClinicalGeniusSupplyChain.dbo.InsurancePlans isp_s WITH(NOLOCK) 
                ON isp_s.PlanGuid = ppy_s.PayerPlan
            INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc_s WITH(NOLOCK) 
                ON isc_s.ContractGuid = isp_s.ContractGuid
            WHERE pyc_s.ClaimGuid = ISNULL(s.ClaimGuid, @ResolvedClaimGuid)
        ) contract_info
        WHERE s.PatientVisit = @PatientVisit 
          AND s.Status = 'Completed'
          AND s.Facility = @FacilityId
          AND ISNULL(s.NoBill, 0) = 0
          AND (
              (@TargetClaimGuid = 'Patient' AND s.ClaimGuid IS NULL) OR
              (@TargetClaimGuid <> 'Patient' AND s.ClaimGuid = @TargetClaimGuid)
          );

        -- 5.4b Execution Pipeline Matrix
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
                sp.EnteredBy,
                sp.ProcedureGuid,
                itm.ItemMasterGuid,
                itm.Type,
                itm.Category,
                itm.ItemNumber, /* <--- ADD THIS COLUMN */
                pa.ProcedureDescription,
                actual_prim.PrimaryPerformedCupsCode AS BundleCupsCode,
                CASE 
                    WHEN scx.ResolvedNightCharges = 0 OR scx.Priority <> 'Urgente' THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN DATENAME(weekday, scx.DateTimePerformed) = 'Sunday' THEN 4 
                    WHEN DATEPART(hour, scx.DateTimePerformed) < 7 THEN 3 
                    WHEN DATEPART(hour, scx.DateTimePerformed) > 18 THEN 3
                    ELSE 2 
                END AS RowShiftType
            FROM #SurgeryContext scx
            INNER JOIN ClinicalGeniusSupplyChain.dbo.SurgeryProcedures sp WITH(NOLOCK)
                ON sp.SurgeryGuid = scx.SurgeryGuid AND sp.Active = 1
            INNER JOIN ClinicalGeniusSupplyChain.dbo.ItemMaster itm WITH(NOLOCK)
                ON itm.ItemMasterGuid = sp.ProcedureGuid
            INNER JOIN ClinicalGeniusEHR.dbo.PatientProcedureAdministration pa WITH(NOLOCK)
                ON pa.ProcedureGuid = sp.ProcedureGuid
            LEFT JOIN #ColombianHolidays h ON h.HolidayDate = CAST(scx.DateTimePerformed AS DATE)
            OUTER APPLY (
                SELECT TOP 1 pai_prim.RVSCode AS PrimaryPerformedCupsCode
                FROM ClinicalGeniusSupplyChain.dbo.SurgeryProcedures sp_prim WITH(NOLOCK)
                INNER JOIN ClinicalGeniusEhr.dbo.PatientProcedureAdministration pai_prim WITH(NOLOCK)
                    ON sp_prim.ProcedureGuid = pai_prim.ProcedureGuid
                WHERE sp_prim.SurgeryGuid = scx.SurgeryGuid
                  AND sp_prim.Active = 1
                ORDER BY sp_prim.IsPrimary DESC, sp_prim.IncisionNumber ASC
            ) actual_prim
        ),
       ProceduresWithCodes AS (
            SELECT 
                rp.*, 
                CASE WHEN rp.ResolvedManual = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4)) 
                     WHEN rp.ResolvedManual = 'ISS_2001' THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                     ELSE 0.00 END AS ManualValue,
                CASE WHEN rp.ResolvedManual = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS INT) 
                     WHEN rp.ResolvedManual = 'ISS_2001' THEN TRY_CAST(mvx.SOATValue AS INT)
                     ELSE NULL END AS SurgeryGroup,
                CASE WHEN rp.ResolvedManual = 'SOAT' THEN mvx.SOATArticle 
                     WHEN rp.ResolvedManual = 'ISS_2001' THEN mvx.ISS2001Article
                     ELSE NULL END AS ArticleGroup,
                pai.RVSCode AS CUPSCode
            FROM RawProcedureEntries rp
            INNER JOIN ClinicalGeniusEhr.dbo.PatientProcedureAdministration pai WITH(NOLOCK) 
                ON rp.ProcedureGuid = pai.ProcedureGuid 
            OUTER APPLY (
                SELECT TOP 1 
                    SOATValue, SOATArticle,
                    ISS2001Value, ISS2001UVR, ISS2001Article
                FROM ClinicalGeniusSupplyChain.dbo.Staging_ManualValues mvl WITH(NOLOCK)
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
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ColombiaContractExceptions ce WITH(NOLOCK) 
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
                CASE 
                    WHEN f.SubtypeCode = 1 THEN 'Surgeon'
                    WHEN f.SubtypeCode = 2 THEN 'Anesthesia' 
                    WHEN f.SubtypeCode = 3 THEN 'Assistant1'
                    WHEN f.SubtypeCode = 6 THEN 'Assistant2'
                    ELSE NULL 
                END AS ResolvedProfessionalType,
                CASE 
                    WHEN f.SubtypeCode = 1 THEN f.SurgeonId
                    WHEN f.SubtypeCode = 2 THEN f.Anesthesiologist
                    WHEN f.SubtypeCode = 3 THEN f.SurgeonId2
                    WHEN f.SubtypeCode = 6 THEN f.SurgeonId3
                    ELSE NULL 
                END AS ResolvedProfessionalId,
                CAST(
                    CASE 
                        WHEN f.NoBill = 1 THEN 0.00
                        WHEN f.IsBundledInPackage = 1 THEN 0.00
                        WHEN f.ExceptionRanking IN (3, 5, 7, 8) THEN f.ExceptionPriceValue * f.ShiftMultiplier
                        ELSE (f.RawCatalogUnits * f.ShiftMultiplier * f.AppliedExceptionFactor * f.DegradationMultiplier * f.UnitMonetaryValue)
                    END AS DECIMAL(18,2)
                ) AS CalculatedLineTotal
            FROM FinalShiftAdjustments f
        )
        SELECT * 
        INTO #SurgeryLineItems
        FROM CalculatedLineItems
        -- FIX: Suppress $0 Room/Materials AND legally restricted $0 Assistant charges
        WHERE NOT (SubtypeCode IN (3, 4, 5, 6) AND CalculatedLineTotal = 0);
        
        -- ==========================================================================================
        -- 5.4c STATE INVALIDATION WORKFLOW (Update & Reset for Honorary Fees on Plan Change)
        -- ==========================================================================================
        
        DECLARE @SystemActionUser NVARCHAR(100) = 'System: Liquidation Engine';
        DECLARE @Reason NVARCHAR(500) = 'Forced recalculation due to Insurance Plan/Contract change.';

        -- 1. Log the system override into the audit table FIRST
        INSERT INTO ClinicalGeniusSupplyChain.dbo.FeeManagementAudits (
            AuditId, TransactionGuid, ActionByUser, ActionType, 
            OldWorkflowStatus, NewWorkflowStatus, 
            OldAmount, NewAmount, ReasonCode, InternalNotes
        )
        SELECT 
            CAST(NEWID() AS NVARCHAR(50)), 
            pt.TransactionGuid, 
            @SystemActionUser, 
            'System Recalculation',
            pt.CurrentWorkflowStatus, 
            'Pending Re-Approval', 
            pt.NetAmount, 
            f.CalculatedLineTotal, 
            'PLAN_CHANGE', 
            @Reason
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt
        INNER JOIN #SurgeryLineItems f 
            ON f.SurgeryGuid = pt.SurgeryGuid
            AND f.ResolvedProfessionalId = pt.ChargePhysician
            AND f.SubtypeCode IN (1, 2, 3, 6) -- Matches Surgeon, Anesthesia, Assistants
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Facility = @FacilityId
          AND pt.TransactionType = 'Honorary'
          AND pt.Status = 'Active'
          AND pt.DIANInvoiceBatchId IS NULL
          AND pt.CurrentWorkflowStatus <> 'Pending Review'
          -- Trigger if the claim changed or the contract amount changed
          AND (pt.ClaimGuid <> f.ResolvedClaimGuid OR pt.NetAmount <> f.CalculatedLineTotal);

       -- 2. Update the main transaction ledger in-place for those exact rows
        UPDATE pt
        SET 
            pt.NetAmount = f.CalculatedLineTotal,
            pt.PerItemChargeAmount = ROUND(f.CalculatedLineTotal + CASE WHEN f.DiagnosisCode LIKE '%Z41.[189]%' THEN f.CalculatedLineTotal * 0.19 ELSE 0.00 END, 2),
            pt.TaxAmount = CASE WHEN f.DiagnosisCode LIKE '%Z41.[189]%' THEN ROUND(f.CalculatedLineTotal * 0.19, 2) ELSE 0.00 END,
            pt.OriginalCalculatedAmount = f.CalculatedLineTotal, 
            pt.CurrentWorkflowStatus = 'Pending Re-Approval',
            pt.ApprovedForBilling = 0, -- Forces the transaction back into the professional's approval queue
            pt.ClaimGuid = f.ResolvedClaimGuid,
            pt.ContractGuid = f.ResolvedContractGuid,
            pt.RevenueCode = f.ResolvedManual,
            pt.DateTimeLastUpdated = GETDATE(),
            pt.LastUpdatedBy = 'System: Plan Change'
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt
        INNER JOIN #SurgeryLineItems f 
            ON f.SurgeryGuid = pt.SurgeryGuid
            AND f.ResolvedProfessionalId = pt.ChargePhysician
            AND f.SubtypeCode IN (1, 2, 3, 6)
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Facility = @FacilityId
          AND pt.TransactionType = 'Honorary'
          AND pt.Status = 'Active'
          AND pt.DIANInvoiceBatchId IS NULL
          AND pt.CurrentWorkflowStatus <> 'Pending Review'
          AND (pt.ClaimGuid <> f.ResolvedClaimGuid OR pt.NetAmount <> f.CalculatedLineTotal);

        -- Track A: Individual Surgical Sub-Lines
        INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid, 
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
            PerItemChargeAmount, DispensingValue, CodigoVIDA, [Status], ChargeCode, ChargePhysician,TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,CurrentWorkflowStatus
        )
        SELECT 
            @FacilityId, 
            @PatientId, 
            @PatientVisit, 
            CASE 
                WHEN f.SubtypeCode IN (1, 2, 3, 6) THEN 'Honorary'
                WHEN f.SubtypeCode = 4 THEN 'RoomRights'
                WHEN f.SubtypeCode = 5 THEN 'Materials' 
                ELSE 'Surgery'
            END AS TransactionType,
            f.SurgeryGuid, --OrderGuid      
            f.ResolvedClaimGuid,                         
            f.SurgeryGuid, 
            f.ResolvedContractGuid, 
            f.ExceptionGuid,                    
            '04',           -- Ambito                    
            f.UnitMonetaryValue,                
            f.SubtypeName AS SurgicalComponent,                      
            f.SurgeryGroup, 
            f.SurgeryApproach,                  
            CASE WHEN f.RankWithinIncision > 1 THEN 1 ELSE 0 END AS SurgicalSequence, 
            f.RowShiftType,                     
            0.00 AS SurchargeAmount,                               
            f.CUPSCode,                         
            NULL AS CUMCode,                               
            f.DateTimePerformed,                
            GETDATE() AS DateTimeEntered,                          
            f.ResolvedManual AS RevenueCode,                            
            1 AS Quantity,                                  
            f.SpecialistProcedureRank AS ItemCost,                    
            f.DiagnosisCode AS ItemSnomedCode,                       
            f.RawCatalogUnits AS ItemAlternateCode,                  
            f.AppliedExceptionFactor AS LocalAmount,              
            f.DegradationMultiplier AS USDBasePrice,            
            f.ShiftMultiplier AS USDPerItemChargeAmount,        
            f.ValueBasis AS PaymentType,                       
            ROUND(f.CalculatedLineTotal, 2) AS NetAmount,                 
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.CalculatedLineTotal * 0.19, 2) 
                ELSE 0.00 
            END AS TaxAmount,                               
            0.00 AS DiscountAmount,                               
            ROUND(f.CalculatedLineTotal + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.CalculatedLineTotal * 0.19, 2) 
                    ELSE 0.00 
                END, 2) AS PerItemChargeAmount,       
            0.00 AS DispensingValue,
            NULL AS CodigoVIDA,
            CASE WHEN f.NoBill = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status],
            f.ResolvedProfessionalType,
            f.ResolvedProfessionalId,
            NEWID(),
            'Unidad',
            NULL, 
            f.ProcedureGuid,
            f.ProcedureDescription,
            f.ItemNumber,       /* <--- CHANGED FROM f.CUPSCode */
            f.Type,
            f.Category,
            f.EnteredBy,
            f.DateTimePerformed,
            CASE WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN 0.19 ELSE 0.00 END, 
            0, -- Discount rate
            f.ProcedureDescription,
            f.CalculatedLineTotal,
            'Pending Review'

        FROM #SurgeryLineItems f
        WHERE NOT EXISTS (
            SELECT 1 
            FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK)
            WHERE pt.SurgeryGuid = f.SurgeryGuid
              AND pt.ChargePhysician = f.ResolvedProfessionalId
              AND pt.TransactionType = 'Honorary'
              AND pt.Status = 'Active' 
        );

        -- Track B: Bundle Master Header Line
        INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid, 
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
            PerItemChargeAmount, DispensingValue, CodigoVIDA, [Status], ChargeCode, ChargePhysician,TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,CurrentWorkflowStatus
        )
        SELECT 
            @FacilityId, 
            @PatientId, 
            @PatientVisit, 
            'BundleMaster' AS TransactionType, 
            f.SurgeryGuid, --OrderGuid
            f.ResolvedClaimGuid, 
            f.SurgeryGuid, 
            f.ResolvedContractGuid, 
            NULL AS ContractExceptionGuid, 
            '04', --Ambity
            f.BundlePrice AS BaseUnitValue, 
            'Paquete Completo' AS SurgicalComponent, 
            NULL AS SurgicalGroup, 
            MAX(f.SurgeryApproach) AS SurgicalApproach, 
            0 AS SurgicalSequence, 
            1 AS ShiftTypeApplied, 
            0.00 AS SurchargeAmount, 
            f.BundleCupsCode AS CupsCode,       
            NULL AS CUMCode, 
            f.DateTimePerformed, 
            GETDATE() AS DateTimeEntered, 
            f.ResolvedManual AS RevenueCode, 
            1 AS Quantity, 
            0.00 AS ItemCost, 
            f.DiagnosisCode AS ItemSnomedCode, 
            NULL AS ItemAlternateCode, 
            f.BundlePrice AS LocalAmount, 
            1.00 AS USDBasePrice, 
            1.00 AS USDPerItemChargeAmount, 
            'COP' AS PaymentType, 
            ROUND(f.BundlePrice, 2) AS NetAmount,         
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.BundlePrice * 0.19, 2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.BundlePrice + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.BundlePrice * 0.19, 2) 
                    ELSE 0.00 
                END, 2) AS PerItemChargeAmount, 
            0.00 AS DispensingValue,
            NULL AS CodigoVIDA,
            'Active' AS [Status],
            NULL AS ProfessionalType,
            NULL AS ProfessionalId,
            NEWID(),
            'Unidad',
            NULL, 
            MAX(f.ProcedureGuid),
            MAX(f.ProcedureDescription),
            MAX(f.ItemNumber),  /* <--- CHANGED FROM f.BundleCupsCode */
            NULL, 
            NULL, 
            MAX(f.EnteredBy),
            f.DateTimePerformed,
            CASE WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN 0.19 ELSE 0.00 END, 
            0, -- Discount rate
            MAX(f.ProcedureDescription),
            f.BundlePrice,
            'Pending Review'
        FROM #SurgeryLineItems f
        WHERE f.IsBundle = 1                    
        GROUP BY f.SurgeryGuid, f.BundleCupsCode, f.BundleDescription, f.BundlePrice, f.DateTimePerformed, f.ResolvedClaimGuid, f.ResolvedContractGuid, f.ResolvedManual, f.DiagnosisCode;

        -- Track C: Surgery - Apply additional surgery charges
        INSERT INTO ClinicalGeniusSupplyChain.dbo.PatientTransactions (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid, 
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach, 
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime, 
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount, 
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount, 
            PerItemChargeAmount, DispensingValue, CodigoVIDA, [Status], ChargeCode, ChargePhysician,TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,CurrentWorkflowStatus
        )
        SELECT 
            @FacilityId,
            @PatientId,
            @PatientVisit,
            'Supplies',  
            scx.SurgeryGuid, -- OrderGuid        
            scx.ResolvedClaimGuid,
            scx.SurgeryGuid,
            scx.ResolvedContractGuid,
            NULL,          
            '04', -- Ambity          
            CAST(ISNULL(sc.BasePrice, 0.00) AS DECIMAL(18,2)),
            ISNULL(itm.ItemName, 'Material Especial / Osteosintesis'),
            NULL,
            NULL,
            0,
            2,                  
            0.00,
            itm.ItemNumber,             
            itm.ItemNumber,              
            ISNULL(scx.DateTimePerformed, sc.DateTimeEntered),
            GETDATE(),
            scx.ResolvedManual,
            ISNULL(sc.Quantity, 1),
            0.00, 
            scx.DiagnosisCode,
            sc.SurgeryUOM,    
            ISNULL(itm.BasePrice, 0.00), -- CRITICAL: Ensure you add the 'itm' JOIN below
            1.00,
            1.00,
            'COP',                   
            calc.NetAmount, 
            calc.TaxAmount,
            0.00,
            calc.NetAmount + calc.TaxAmount, -- Much cleaner calculation
            0.00 AS DispensingValue,
            NULL AS CodigoVIDA,
            CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 'Unbillable' ELSE 'Active' END,
            NULL, -- Mapped to ChargeCode (was aliased as ProfessionalType)
            NULL,  -- Mapped to ChargePhysician (was aliased as ProfessionalId)
            NEWID(),
            'Procedimiento',
            NULL, --note
            itm.ItemMasterGuid,
            itm.ItemName,
            itm.ItemNumber,
            itm.Type,
            itm.Category,
            sc.EnteredBy,
            sc.DateTimeEntered,
            CASE WHEN scx.DiagnosisCode LIKE '%Z41.1%' OR scx.DiagnosisCode LIKE '%Z41.8%' OR scx.DiagnosisCode LIKE '%Z41.9%' THEN 0.19 ELSE 0.00 END, 
            0,
            itm.ItemName,
            calc.NetAmount,
            'Pending Review'
        FROM ClinicalGeniusEhr.dbo.SurgeryCharges sc WITH(NOLOCK) 
        INNER JOIN ClinicalGeniusSupplyChain.dbo.SurgeryProcedures sp WITH(NOLOCK)
            ON sp.SurgeryProcedureGuid = sc.SurgeryProcedureGuid
        INNER JOIN #SurgeryContext scx 
            ON scx.SurgeryGuid = sp.SurgeryGuid
        INNER JOIN ClinicalGeniusSupplyChain.dbo.ItemMaster itm WITH(NOLOCK) 
             ON sc.ItemMasterGuid = itm.ItemMasterGuid 
        CROSS APPLY (
            -- Calculate base values once so they can be reused without copy-pasting case statements
            SELECT 
                ROUND(CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 0.00 ELSE ISNULL(sc.NetAmount, 0.00) END, 2) AS NetAmount,
                CASE 
                    WHEN scx.DiagnosisCode LIKE '%Z41.1%' OR scx.DiagnosisCode LIKE '%Z41.8%' OR scx.DiagnosisCode LIKE '%Z41.9%' THEN 
                        ROUND((CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN 0.00 ELSE ISNULL(sc.NetAmount, 0.00) END) * 0.19, 2)
                    ELSE 0.00 
                END AS TaxAmount
        ) calc
        WHERE sc.Facility = @FacilityId             
        AND sc.Active = 1;

       -- ##########################################################################################
        -- ##  STAGE 2: CALCULATE COPAY (only applies to a payer claim; 'Patient' has no PayerClaims row)
        -- ##########################################################################################

        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            -- Extract patient financial class and admission year based on the visit
            SELECT TOP 1 
                @PatientFinancialClass = pat.FinancialClass,
                @CopayYearOfService = YEAR(pvt.AdmitDateTime)
            FROM ClinicalGeniusEhr.dbo.PatientVisits pvt WITH(NOLOCK)
            INNER JOIN ClinicalGeniusEhr.dbo.PatientTable pat WITH(NOLOCK)
                ON pat.RecordUniqueId = pvt.PatientId
            WHERE pvt.PatientVisitUniqueId = @PatientVisit 
              AND pvt.FacilityId = @FacilityId;

            IF @CopayYearOfService IS NULL SET @CopayYearOfService = YEAR(GETDATE());

            SELECT TOP 1 @MaxAllowedCopayPerEvent = scl.MaxCapPerEvent
            FROM #StatutoryCopayLimits scl
            WHERE scl.CalendarYear = @CopayYearOfService AND scl.FinancialClass = @PatientFinancialClass;

            IF @MaxAllowedCopayPerEvent IS NULL SET @MaxAllowedCopayPerEvent = 99999999.99;
            IF @PatientFinancialClass = 'S1' SET @MaxAllowedCopayPerEvent = 0.00;

            -- 2.1 Base Aggregation: Strictly restricted to the target claim
            UPDATE pyc
            SET pyc.MedicalCoinsurance = ROUND(ClaimTotals.TotalNet * (ISNULL(pyc.CoInsurance, 0.00) / 100.00), 2),
                pyc.PayerCoverageAmount = ROUND(ClaimTotals.TotalNet - ISNULL(pyc.Copay, 0.00) - ROUND(ClaimTotals.TotalNet * (ISNULL(pyc.CoInsurance, 0.00) / 100.00), 2), 2),
                pyc.LastUpdatedBy = 'CopayEngine_InitialAgg'
            FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc
            CROSS APPLY (
                SELECT ISNULL(SUM(pt.NetAmount), 0.00) AS TotalNet
                FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK)
                WHERE pt.ClaimGuid = @TargetClaimGuid
                  AND pt.Status = 'Active'
                  AND pt.Facility = @FacilityId
            ) ClaimTotals
            WHERE pyc.ClaimGuid = @TargetClaimGuid
              AND pyc.Facility = @FacilityId;

            -- 2.2 Event Evaluation: Sum prior claims vs. current claim
            SELECT @PriorVisitLiability = ISNULL(SUM(ISNULL(Copay, 0.00) + ISNULL(MedicalCoinsurance, 0.00)), 0.00)
            FROM ClinicalGeniusSupplyChain.dbo.PayerClaims WITH(NOLOCK)
            WHERE PatientVisit = @PatientVisit 
              AND Facility = @FacilityId
              AND ClaimGuid != @TargetClaimGuid;

            SELECT @CurrentClaimLiability = ISNULL(Copay, 0.00) + ISNULL(MedicalCoinsurance, 0.00)
            FROM ClinicalGeniusSupplyChain.dbo.PayerClaims WITH(NOLOCK)
            WHERE ClaimGuid = @TargetClaimGuid
              AND Facility = @FacilityId;

            -- 2.3 Cap Enforcement: Trim current claim if the event cap is breached
            IF (@PriorVisitLiability + @CurrentClaimLiability) > @MaxAllowedCopayPerEvent
            BEGIN
                SET @AvailableCapSpace = @MaxAllowedCopayPerEvent - @PriorVisitLiability;
                IF @AvailableCapSpace < 0 SET @AvailableCapSpace = 0.00;

                UPDATE pyc
                SET pyc.Copay = ROUND(CASE WHEN pyc.Copay > @AvailableCapSpace THEN @AvailableCapSpace ELSE pyc.Copay END, 2),
                    pyc.MedicalCoinsurance = ROUND(CASE WHEN pyc.Copay >= @AvailableCapSpace THEN 0.00 ELSE (@AvailableCapSpace - pyc.Copay) END, 2),
                    pyc.PayerCoverageAmount = ROUND(pyc.PayerCoverageAmount + (@CurrentClaimLiability - @AvailableCapSpace), 2),
                    pyc.LastUpdatedBy = 'CopayEngine_EventCapped'
                FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc
                WHERE pyc.ClaimGuid = @TargetClaimGuid
                  AND pyc.Facility = @FacilityId;
            END
        END

        -- Liquidation + Copay are committed atomically
        COMMIT TRANSACTION;

        -- ##########################################################################################
        -- ##  STAGE 3: INVOICE SCRUBBER (read-only, runs over the committed result)
        -- ##########################################################################################
        SELECT TOP 1
            @PatientSex = ISNULL(pat.PatientSex, 'Indeterminate'),
            -- Calculates exact age accounting for leap years and birth month/day
            @AgeInYears = DATEDIFF(YY, pat.PatientDOB, GETDATE()) - 
                          CASE WHEN DATEADD(YY, DATEDIFF(YY, pat.PatientDOB, GETDATE()), pat.PatientDOB) > GETDATE() THEN 1 ELSE 0 END
        FROM ClinicalGeniusEhr.dbo.PatientTable pat WITH(NOLOCK)
        WHERE pat.RecordUniqueId = @PatientId;   -- PatientVisits.PatientId -> PatientTable.RecordUniqueId

        -- By grouping by OrderGuid (which uniquely identifies the clinical order/surgery event),
        -- we easily collapse the 6 surgical sub-lines (Surgeon, Anesthesia, Room, etc.) to 1 clinical quantity.
        ;WITH VisitAggregates AS (
            SELECT 
                CupsCode, 
                SUM(LineQty) AS TotalVisitQuantity
            FROM (
                SELECT 
                    CupsCode, 
                    ISNULL(OrderGuid, TransactionGuid) AS DistinctOrderRef,
                    MAX(TransactionQuantity) AS LineQty
                FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(NOLOCK)
                WHERE PatientVisit = @PatientVisit
                  AND Facility = @FacilityId
                  AND Status = 'Active'
                  AND Status <> 'Unbillable'
                  AND (
                      (@TargetClaimGuid = 'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = 'Patient')) OR
                      (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
                  )
                GROUP BY CupsCode, ISNULL(OrderGuid, TransactionGuid)
            ) a
            GROUP BY CupsCode
        ),
        ScrubberEvaluations AS (
            SELECT 
                pt.TransactionType,       
                pt.OrderGuid,             
                pt.CupsCode,
                c.CUPSName AS ItemDescription,
                pt.TransactionQuantity AS LineQuantity,
                va.TotalVisitQuantity,
                pt.DateTimeEntered,
                
                -- Error 1: Gender Mismatch
                CASE 
                    WHEN c.Sexo = 'F' AND @PatientSex = 'Male' THEN 'Incoherencia de género: procedimiento exclusivo para mujeres facturado a un paciente varón.'
                    WHEN c.Sexo = 'M' AND @PatientSex = 'Female' THEN 'Incongruencia de género: procedimiento exclusivo para hombres facturado a una paciente mujer.'
                    ELSE NULL 
                END AS GenderError,

                -- Error 2: Quantity Limit Exceeded
                CASE 
                    WHEN TRY_CAST(c.Cant_max AS INT) > 0 AND va.TotalVisitQuantity > TRY_CAST(c.Cant_max AS INT) 
                    THEN CONCAT('Cantidad excedida: Facturado ', va.TotalVisitQuantity, '. El máximo permitido por visita es ', c.Cant_max, '.')
                    ELSE NULL 
                END AS QuantityError,
                
                -- Error 3: Missing Required Diagnosis
                CASE 
                    WHEN c.Dx_requerido = '1' AND pt.ItemSnomedCode IS NULL 
                    THEN 'Diagnóstico requerido: este procedimiento no se puede facturar sin un código ICD-10 asociado.'
                    ELSE NULL 
                END AS DiagnosisError,

                -- Partition identical procedure error lines by OrderGuid and CupsCode so the UI gets exactly 1 row per issue.
                ROW_NUMBER() OVER (
                    PARTITION BY pt.OrderGuid, pt.CupsCode 
                    ORDER BY 
                        CASE WHEN pt.TransactionType IN ('Surgery', 'Procedure', 'BundleMaster', 'Honorary') THEN 1 ELSE 2 END,
                        pt.DateTimeEntered DESC
                ) AS DedupRank

            FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK)
            INNER JOIN VisitAggregates va ON pt.CupsCode = va.CupsCode
            INNER JOIN ClinicalGeniusSupplyChain.dbo.COLCups c WITH(NOLOCK) ON pt.CupsCode = c.CUPSCode
            WHERE pt.PatientVisit = @PatientVisit
              AND pt.Facility = @FacilityId
              AND pt.Status = 'Active' 
              AND pt.Status <> 'Unbillable'
              AND (
                  (@TargetClaimGuid = 'Patient' AND (pt.ClaimGuid IS NULL OR pt.ClaimGuid = 'Patient')) OR
                  (@TargetClaimGuid <> 'Patient' AND pt.ClaimGuid = @TargetClaimGuid)
              )
        )
       -- ==========================================================================================
        -- 4. Return the Defect Queue to the UI 
        -- ==========================================================================================
        SELECT 
            OrderGuid,               
            TransactionType,
            CupsCode,
            ItemDescription,
            LineQuantity,
            TotalVisitQuantity,
            DateTimeEntered,
            ScrubberViolationMessage
        FROM (
            SELECT 
                OrderGuid,
                TransactionType,
                CupsCode,
                ItemDescription,
                LineQuantity,
                TotalVisitQuantity,
                DateTimeEntered,
                DedupRank,
                ISNULL(STUFF(
                    ISNULL(' | ' + GenderError, '') +
                    ISNULL(' | ' + QuantityError, '') +
                    ISNULL(' | ' + DiagnosisError, ''),
                1, 3, ''), '') AS ScrubberViolationMessage
            FROM ScrubberEvaluations
        ) FinalDefects
        WHERE ScrubberViolationMessage <> ''
          AND DedupRank = 1
        ORDER BY DateTimeEntered ASC;

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
    IF OBJECT_ID('tempdb..#ColombianHolidays')    IS NOT NULL DROP TABLE #ColombianHolidays;
    IF OBJECT_ID('tempdb..#UnitParameters')       IS NOT NULL DROP TABLE #UnitParameters;
    IF OBJECT_ID('tempdb..#StatutoryCopayLimits') IS NOT NULL DROP TABLE #StatutoryCopayLimits;
    IF OBJECT_ID('tempdb..#SurgeryContext')       IS NOT NULL DROP TABLE #SurgeryContext;
    IF OBJECT_ID('tempdb..#SurgeryLineItems')     IS NOT NULL DROP TABLE #SurgeryLineItems;
END;
GO