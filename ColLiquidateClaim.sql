SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID(N'odata') IS NULL
    EXEC(N'CREATE SCHEMA [odata]');
GO

IF OBJECT_ID(N'[odata].[COLLiquidateClaim]', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE [odata].[COLLiquidateClaim] AS BEGIN SET NOCOUNT ON; END');
GO

-- ==========================================================================================
-- Procedure: [odata].[COLLiquidateClaim]
-- Purpose: Multi-module Colombian clinical fee liquidation engine (Stays, Labs, Imaging,
--          Medications with Resolution 948 DispensingValue, Outpatient Procedures, Multi-Staff
--          Surgeries, Statutory Copay/Coinsurance Capping, and CUPS Claim Scrubber).
-- Target: SQL Server 2014+
-- ==========================================================================================
ALTER PROCEDURE [odata].[COLLiquidateClaim]
    @PatientVisit    NVARCHAR(50),
    @FacilityId      NVARCHAR(100) = NULL,
    @TargetClaimGuid NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @PatientVisit = LTRIM(RTRIM(@PatientVisit));
    SET @FacilityId = LTRIM(RTRIM(@FacilityId));
    SET @TargetClaimGuid = ISNULL(NULLIF(LTRIM(RTRIM(@TargetClaimGuid)), N''), N'Patient');

    IF NULLIF(@PatientVisit, N'') IS NULL
        THROW 50001, N'Validation Failure: @PatientVisit is required.', 1;

    IF NULLIF(@FacilityId, N'') IS NULL
        THROW 50002, N'Validation Failure: @FacilityId is required.', 1;

    -- ==========================================================================================
    -- 0. SHARED CONTEXT RESOLUTION
    -- ==========================================================================================
    DECLARE @TranCount             INT = @@TRANCOUNT,
            @Now                   DATETIME2(7) = SYSDATETIME(),
            @PatientId             NVARCHAR(50),
            @VisitDiagnosis        NVARCHAR(50),
            @ResolvedClaimGuid     NVARCHAR(50),
            @ResolvedContractGuid  NVARCHAR(50),
            @ResolvedManual        VARCHAR(20),
            @ResolvedAdjustmentPct DECIMAL(5,2),
            @ResolvedNightCharges  BIT,
            @ClaimVisitCheck       NVARCHAR(50);

    SELECT TOP (1)
        @PatientId = pvt.PatientId
    FROM ClinicalGeniusEhr.dbo.PatientVisits pvt
    WHERE pvt.PatientVisitUniqueId = @PatientVisit
      AND (pvt.FacilityId = @FacilityId OR pvt.FacilityId IS NULL)
    ORDER BY CASE WHEN pvt.FacilityId = @FacilityId THEN 0 ELSE 1 END ASC;

    IF @PatientId IS NULL
        THROW 50003, N'Validation Failure: PatientVisit was not found for the specified FacilityId.', 1;

    SELECT TOP (1)
        @VisitDiagnosis = NULLIF(LTRIM(RTRIM(prb.ProblemCode)), N'')
    FROM ClinicalGeniusEhr.dbo.PatientProblemList prb
    WHERE prb.PatientVisit = @PatientVisit
      AND prb.ProblemStatus = N'Active'
    ORDER BY prb.ProblemDateTimeEntered DESC;

    SET @VisitDiagnosis = ISNULL(@VisitDiagnosis, N'none');

    IF @TargetClaimGuid = N'Patient'
    BEGIN
        SET @ResolvedClaimGuid     = N'Patient';
        SET @ResolvedContractGuid  = NULL;
        SET @ResolvedManual        = 'SOAT';
        SET @ResolvedAdjustmentPct = 0.00;
        SET @ResolvedNightCharges  = 0;
    END
    ELSE
    BEGIN
        SELECT TOP (1)
            @ResolvedClaimGuid     = pyc.ClaimGuid,
            @ClaimVisitCheck       = pyc.PatientVisit,
            @ResolvedContractGuid  = isc.ContractGuid,
            @ResolvedManual        = ISNULL(NULLIF(LTRIM(RTRIM(isc.EntityCode)), ''), 'SOAT'),
            @ResolvedAdjustmentPct = ISNULL(isc.AdjustmentPct, 0.00),
            @ResolvedNightCharges  = ISNULL(isc.NightCharges, 0)
        FROM [dbo].[PayerClaims] pyc
        LEFT JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy
            ON ppy.PatientPayerGuid = pyc.PayerGuid
        LEFT JOIN [dbo].[InsurancePlans] isp
            ON isp.PlanGuid = ppy.PayerPlan
        LEFT JOIN [dbo].[InsuranceContracts] isc
            ON isc.ContractGuid = isp.ContractGuid
        WHERE pyc.ClaimGuid = @TargetClaimGuid
          AND pyc.Facility = @FacilityId;

        IF @ResolvedClaimGuid IS NULL
            THROW 50004, N'Validation Failure: @TargetClaimGuid was not found in PayerClaims for this Facility.', 1;

        IF @ClaimVisitCheck IS NOT NULL AND @ClaimVisitCheck <> @PatientVisit
            THROW 50005, N'Validation Failure: @TargetClaimGuid does not belong to @PatientVisit.', 1;
    END

    -- Copay & Scrubber Context
    DECLARE @PatientFinancialClass   VARCHAR(5)    = 'A',
            @MaxAllowedCopayPerEvent DECIMAL(18,2) = 99999999.99,
            @PriorVisitLiability     DECIMAL(18,2) = 0.00,
            @CurrentClaimLiability   DECIMAL(18,2) = 0.00,
            @AvailableCapSpace       DECIMAL(18,2) = 0.00,
            @CopayYearOfService      INT,
            @NormalizedSex           CHAR(1)       = 'I',
            @AgeInYears              INT;

    -- ==========================================================================================
    -- 0.1 SHARED TEMP TABLES
    -- ==========================================================================================
    IF OBJECT_ID('tempdb..#ColombianHolidays')    IS NOT NULL DROP TABLE #ColombianHolidays;
    IF OBJECT_ID('tempdb..#UnitParameters')       IS NOT NULL DROP TABLE #UnitParameters;
    IF OBJECT_ID('tempdb..#StatutoryCopayLimits') IS NOT NULL DROP TABLE #StatutoryCopayLimits;
    IF OBJECT_ID('tempdb..#SurgeryContext')       IS NOT NULL DROP TABLE #SurgeryContext;
    IF OBJECT_ID('tempdb..#SurgeryLineItems')     IS NOT NULL DROP TABLE #SurgeryLineItems;

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

    CREATE TABLE #UnitParameters (
        ContractType VARCHAR(10) NOT NULL,
        CalendarYear INT NOT NULL,
        UnitCategory VARCHAR(10) NOT NULL,
        UnitValue    DECIMAL(18,2) NOT NULL,
        PRIMARY KEY CLUSTERED (ContractType, CalendarYear, UnitCategory)
    );

    INSERT INTO #UnitParameters (ContractType, CalendarYear, UnitCategory, UnitValue)
    VALUES
        ('SOAT', 2023, 'SMDLV', 38666.67),
        ('SOAT', 2024, 'UVB',   10951.00),
        ('SOAT', 2025, 'UVB',   11552.00),
        ('SOAT', 2026, 'UVB',   12110.00),
        ('SOAT', 2027, 'UVB',   12110.00),
        ('SOAT', 2028, 'UVB',   12110.00),
        ('SOAT', 2029, 'UVB',   12110.00),
        ('SOAT', 2030, 'UVB',   12110.00),
        ('ISS',  2023, 'UVR',   1.00),
        ('ISS',  2024, 'UVR',   1.00),
        ('ISS',  2025, 'UVR',   1.00),
        ('ISS',  2026, 'UVR',   1.00),
        ('ISS',  2027, 'UVR',   1.00),
        ('ISS',  2028, 'UVR',   1.00),
        ('ISS',  2029, 'UVR',   1.00),
        ('ISS',  2030, 'UVR',   1.00);

    CREATE TABLE #StatutoryCopayLimits (
        CalendarYear   INT NOT NULL,
        FinancialClass VARCHAR(5) NOT NULL,
        MaxCapPerEvent DECIMAL(18,2) NOT NULL,
        PRIMARY KEY CLUSTERED (CalendarYear, FinancialClass)
    );

    INSERT INTO #StatutoryCopayLimits (CalendarYear, FinancialClass, MaxCapPerEvent)
    VALUES
        (2023, 'A', 304583.00), (2023, 'B', 1220455.00), (2023, 'C', 2440909.00), (2023, 'S1', 0.00),
        (2024, 'A', 338900.00), (2024, 'B', 1357600.00), (2024, 'C', 2715200.00), (2024, 'S1', 0.00),
        (2025, 'A', 370000.00), (2025, 'B', 1480000.00), (2025, 'C', 2960000.00), (2025, 'S1', 0.00),
        (2026, 'A', 400000.00), (2026, 'B', 1600000.00), (2026, 'C', 3200000.00), (2026, 'S1', 0.00),
        (2027, 'A', 400000.00), (2027, 'B', 1600000.00), (2027, 'C', 3200000.00), (2027, 'S1', 0.00),
        (2028, 'A', 400000.00), (2028, 'B', 1600000.00), (2028, 'C', 3200000.00), (2028, 'S1', 0.00),
        (2029, 'A', 400000.00), (2029, 'B', 1600000.00), (2029, 'C', 3200000.00), (2029, 'S1', 0.00),
        (2030, 'A', 400000.00), (2030, 'B', 1600000.00), (2030, 'C', 3200000.00), (2030, 'S1', 0.00);

    BEGIN TRY
        IF @TranCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION sp_COLLiquidateClaim;

        -- ##########################################################################################
        -- ##  MODULE 1: ROOM CHARGES (Stay)
        -- ##########################################################################################

        IF @TargetClaimGuid <> N'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.PatientBedAssignments WITH (ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND ClaimGuid IS NULL;
        END

        -- Safeguards DIAN-batched and RIPS-batched records while clearing Active & Unbillable staging rows
        UPDATE [dbo].[PatientTransactions] WITH (ROWLOCK, UPDLOCK)
        SET [Status] = N'Canceled',
            DateTimeLastUpdated = @Now,
            LastUpdatedBy = N'PricingEngine_Stays'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = N'Stay'
          AND [Status] IN (N'Active', N'Unbillable')
          AND DIANInvoiceBatchId IS NULL
          AND RIPSBatchId IS NULL
          AND (
              (@TargetClaimGuid = N'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = N'Patient'))
              OR (@TargetClaimGuid <> N'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

        ;WITH Tally(n) AS (
            SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
            FROM sys.all_columns a
            CROSS JOIN (SELECT TOP (2) column_id FROM sys.all_columns) b
        ),
        ExpandedStayDays AS (
            SELECT
                ba.BedAssignmentGuid AS StayGuid,
                ba.EnteredBy,
                ba.DateTimeEntered,
                ba.PatientVisit,
                r.RoomAndBedNumber,
                LTRIM(RTRIM(r.OpenErpBedId)) AS BedCategoryCode,
                @FacilityId AS FacilityId,
                @VisitDiagnosis AS DiagnosisCode,
                CAST(DATEADD(DAY, t.n, CAST(ba.DateTimeAssigned AS DATE)) AS DATE) AS StayCalendarDate,
                YEAR(DATEADD(DAY, t.n, CAST(ba.DateTimeAssigned AS DATE))) AS YearOfService,
                ba.DateTimeAssigned,
                ba.DateTimeCheckedOut
            FROM ClinicalGeniusEhr.dbo.PatientBedAssignments ba
            INNER JOIN [dbo].[FacilityPatientRooms] r
                ON r.RoomGuid = ba.RoomGuid
            INNER JOIN Tally t
                ON (
                    -- Exclude discharge date on multi-day stays; bill 1 day on same-day stay or active open stay
                    (
                        ba.DateTimeCheckedOut IS NOT NULL
                        AND CAST(ba.DateTimeCheckedOut AS DATE) > CAST(ba.DateTimeAssigned AS DATE)
                        AND t.n < DATEDIFF(DAY, CAST(ba.DateTimeAssigned AS DATE), CAST(ba.DateTimeCheckedOut AS DATE))
                    )
                    OR (
                        (ba.DateTimeCheckedOut IS NULL OR CAST(ba.DateTimeCheckedOut AS DATE) <= CAST(ba.DateTimeAssigned AS DATE))
                        AND t.n <= CASE
                            WHEN ba.DateTimeCheckedOut IS NULL
                            THEN DATEDIFF(DAY, CAST(ba.DateTimeAssigned AS DATE), CAST(@Now AS DATE))
                            ELSE 0
                        END
                    )
                )
            WHERE ba.PatientVisit = @PatientVisit
              AND ba.Facility = @FacilityId
              AND ba.DateTimeAssigned IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(r.OpenErpBedId)), N'') IS NOT NULL
              AND (
                  (@TargetClaimGuid = N'Patient' AND (ba.ClaimGuid IS NULL OR ba.ClaimGuid = N'Patient'))
                  OR (@TargetClaimGuid <> N'Patient' AND ba.ClaimGuid = @TargetClaimGuid)
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
                SELECT
                    esd.*,
                    ROW_NUMBER() OVER (
                        PARTITION BY esd.StayCalendarDate
                        ORDER BY esd.DateTimeAssigned DESC, ISNULL(esd.DateTimeCheckedOut, @Now) DESC, esd.StayGuid ASC
                    ) AS RowRank
                FROM ExpandedStayDays esd
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM [dbo].[PatientTransactions] pt_locked
                    WHERE pt_locked.PatientVisit = @PatientVisit
                      AND pt_locked.Facility = @FacilityId
                      AND pt_locked.TransactionType = N'Stay'
                      AND pt_locked.[Status] = N'Active'
                      AND (pt_locked.DIANInvoiceBatchId IS NOT NULL OR pt_locked.RIPSBatchId IS NOT NULL)
                      AND CAST(pt_locked.ExternalProcessedDateTime AS DATE) = esd.StayCalendarDate
                )
            ) ranked
            WHERE ranked.RowRank = 1
        ),
        StaysWithTariffBaselines AS (
            SELECT
                es.*,
                CASE
                    WHEN ISNULL(@ResolvedManual, 'SOAT') = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN @ResolvedManual LIKE 'ISS%'              THEN COALESCE(TRY_CAST(mvx.ISS2001Value AS DECIMAL(18,4)), TRY_CAST(mvx.ISS2001UVR AS DECIMAL(18,4)))
                    ELSE 0.00
                END AS RoomCatalogUnits,
                CASE
                    WHEN ISNULL(@ResolvedManual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle
                    WHEN @ResolvedManual LIKE 'ISS%'              THEN mvx.ISS2001Article
                    ELSE NULL
                END AS ArticleGroup,
                CAST(
                    CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s
                            WHERE s.PatientVisit = es.PatientVisit
                              AND s.Status = N'Completed'
                              AND ISNULL(s.NoBill, 0) = 0
                              AND s.IsBundle = 1
                              AND s.RoomIncluded = 1
                              AND es.StayCalendarDate >= CAST(COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now) AS DATE)
                              AND es.StayCalendarDate <= CAST(DATEADD(DAY, 1, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now)) AS DATE)
                        ) THEN 1
                        ELSE 0
                    END AS BIT
                ) AS IsStayAbsorbedByBundle
            FROM DeduplicatedStayDays es
            OUTER APPLY (
                SELECT TOP (1)
                    mvl.SOATValue, mvl.SOATArticle,
                    mvl.ISS2001Value, mvl.ISS2001UVR, mvl.ISS2001Article
                FROM [dbo].[Staging_ManualValues] mvl
                WHERE mvl.CUPSCode = es.BedCategoryCode
                  AND mvl.YearOfService <= es.YearOfService
                ORDER BY
                    CASE WHEN mvl.YearOfService = es.YearOfService THEN 0 ELSE 1 END ASC,
                    mvl.YearOfService DESC,
                    mvl.RecId DESC
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
            LEFT JOIN [dbo].[ColombiaContractExceptions] ce
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
                SELECT TOP (1) up_inner.UnitValue
                FROM #UnitParameters up_inner
                WHERE up_inner.ContractType = CASE WHEN @ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up_inner.UnitCategory = CASE
                      WHEN ex.StayCalendarDate >= '2024-01-01' AND @ResolvedManual = 'SOAT' THEN 'UVB'
                      WHEN ex.StayCalendarDate < '2024-01-01'  AND @ResolvedManual = 'SOAT' THEN 'SMDLV'
                      ELSE 'UVR'
                  END
                ORDER BY
                    CASE WHEN up_inner.CalendarYear = ex.YearOfService THEN 0 ELSE 1 END ASC,
                    ABS(up_inner.CalendarYear - ex.YearOfService) ASC,
                    up_inner.CalendarYear DESC
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
        INSERT INTO [dbo].[PatientTransactions] (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid,
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach,
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime,
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount,
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount,
            PerItemChargeAmount, [Status], TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount, CurrentWorkflowStatus
        )
        SELECT
            @FacilityId,
            @PatientId,
            @PatientVisit,
            N'Stay',
            f.StayGuid,
            @ResolvedClaimGuid,
            NULL,
            @ResolvedContractGuid,
            f.ExceptionGuid,
            '03',
            f.UnitMonetaryValue,
            N'Día de Estancia Hosp: Category Code ' + f.BedCategoryCode,
            NULL,
            NULL,
            0,
            2,
            0.00,
            f.BedCategoryCode,
            NULL,
            CAST(f.StayCalendarDate AS DATETIME),
            @Now,
            @ResolvedManual,
            1,
            0.00,
            f.DiagnosisCode,
            f.RoomCatalogUnits,
            f.BaseCalculatedValue,
            1.00,
            1.00,
            f.ValueBasis,
            calc.RoundedNet,
            calc.RoundedTax,
            0.00,
            calc.RoundedNet + calc.RoundedTax,
            N'Active',
            NEWID(),
            N'Día',
            N'Hospital Stay',
            NULL,
            N'Hospital Stay',
            f.BedCategoryCode,
            NULL,
            NULL,
            f.EnteredBy,
            f.DateTimeEntered,
            calc.AppliedTaxRate,
            0,
            f.RoomAndBedNumber,
            f.DayLineNetAmount,
            N'Pending Review'
        FROM FinalStayLiquidationLines f
        CROSS APPLY (
            SELECT
                CASE
                    WHEN f.DiagnosisCode LIKE N'%Z41.1%' OR f.DiagnosisCode LIKE N'%Z41.8%' OR f.DiagnosisCode LIKE N'%Z41.9%'
                      OR f.DiagnosisCode LIKE N'%Z411%'  OR f.DiagnosisCode LIKE N'%Z418%'  OR f.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate
        ) tx
        CROSS APPLY (
            SELECT
                ROUND(f.DayLineNetAmount, -2) AS RoundedNet,
                CASE WHEN tx.AppliedTaxRate > 0 THEN ROUND(f.DayLineNetAmount * tx.AppliedTaxRate, -2) ELSE 0.00 END AS RoundedTax,
                tx.AppliedTaxRate
        ) calc;


        -- ##########################################################################################
        -- ##  MODULE 2: DIAGNOSTICS (Labs / Pathology / Imaging)
        -- ##########################################################################################

        IF @TargetClaimGuid <> N'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.LabTestOrders WITH (ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND Status = N'Completed'
              AND ClaimGuid IS NULL;

            UPDATE ClinicalGeniusEhr.dbo.ImagingOrders WITH (ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND OrderStatus = N'Completed'
              AND ClaimGuid IS NULL;
        END

        UPDATE [dbo].[PatientTransactions] WITH (ROWLOCK, UPDLOCK)
        SET [Status] = N'Canceled',
            DateTimeLastUpdated = @Now,
            LastUpdatedBy = N'PricingEngine_Diagnostics'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType IN (N'Laboratory', N'Imaging')
          AND SurgeryGuid IS NULL
          AND [Status] IN (N'Active', N'Unbillable')
          AND DIANInvoiceBatchId IS NULL
          AND RIPSBatchId IS NULL
          AND (
              (@TargetClaimGuid = N'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = N'Patient'))
              OR (@TargetClaimGuid <> N'Patient' AND ClaimGuid = @TargetClaimGuid)
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
                YEAR(ISNULL(lto.DateTimeDrawn, lto.DateTimeOrdered)) AS YearOfService,
                ISNULL(amx.Ambity, '02') AS Ambity,
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                @ResolvedContractGuid AS ResolvedContractGuid,
                @ResolvedManual AS ResolvedManual,
                @ResolvedAdjustmentPct AS ResolvedAdjustmentPct,
                @ResolvedNightCharges AS ResolvedNightCharges,
                COALESCE(NULLIF(LTRIM(RTRIM(lto.AssociatedDiagnosis)), N''), @VisitDiagnosis, N'none') AS DiagnosisCode,
                ISNULL(lto.NoBill, 0) AS NoBill,
                CASE
                    WHEN @ResolvedNightCharges = 0
                         OR ISNULL(amx.Ambity, '02') IN ('01', '02')
                         OR ISNULL(lto.OrderPriority, N'Routine') <> N'STAT' THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN ((DATEPART(WEEKDAY, ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered)) + @@DATEFIRST - 1) % 7) = 0 THEN 4
                    WHEN DATEPART(HOUR, ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered)) < 7 THEN 3
                    WHEN DATEPART(HOUR, ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered)) > 18 THEN 3
                    ELSE 2
                END AS RowShiftType,
                CAST(
                    CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s
                            WHERE s.PatientVisit = lto.PatientVisit
                              AND s.Status = N'Completed'
                              AND ISNULL(s.NoBill, 0) = 0
                              AND s.IsBundle = 1
                              AND s.MaterialIncluded = 1
                              AND ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered) >= DATEADD(HOUR, -24, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now))
                              AND ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered) <= DATEADD(HOUR, 6, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now))
                        ) THEN 1
                        ELSE 0
                    END AS BIT
                ) AS IsLabAbsorbedByBundle
            FROM ClinicalGeniusEhr.dbo.LabTestOrders lto
            INNER JOIN ClinicalGeniusEhr.dbo.LabPanelsByFacility lap
                ON lap.LabPanelGuid = lto.CPTCode
            LEFT JOIN #ColombianHolidays h
                ON h.HolidayDate = CAST(ISNULL(lto.DateTimeUpdated, lto.DateTimeOrdered) AS DATE)
            OUTER APPLY (
                SELECT TOP (1) DPT.Ambity
                FROM ClinicalGeniusEhr.dbo.PatientDepartmentTracking PDT
                INNER JOIN [dbo].[Departments] DPT
                    ON DPT.DepartmentGuid = PDT.DepartmentGuid
                WHERE PDT.PatientVisit = lto.PatientVisit
                  AND lto.DateTimeOrdered >= PDT.StartDateTime
                  AND (lto.DateTimeOrdered <= PDT.StopDateTime OR PDT.StopDateTime IS NULL)
                ORDER BY PDT.StartDateTime DESC
            ) amx
            WHERE lto.PatientVisit = @PatientVisit
              AND lto.Status = N'Completed'
              AND lto.Facility = @FacilityId
              AND (
                  (@TargetClaimGuid = N'Patient' AND (lto.ClaimGuid IS NULL OR lto.ClaimGuid = N'Patient'))
                  OR (@TargetClaimGuid <> N'Patient' AND lto.ClaimGuid = @TargetClaimGuid)
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM [dbo].[PatientTransactions] pt_locked
                  WHERE pt_locked.OrderGuid = lto.OrderGuid
                    AND pt_locked.Facility = @FacilityId
                    AND pt_locked.TransactionType = N'Laboratory'
                    AND pt_locked.[Status] = N'Active'
                    AND (pt_locked.DIANInvoiceBatchId IS NOT NULL OR pt_locked.RIPSBatchId IS NOT NULL)
              )
        ),
        LabLinesWithTariffs AS (
            SELECT
                cl.*,
                CASE
                    WHEN cl.ResolvedManual = 'SOAT'     THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN cl.ResolvedManual LIKE 'ISS%'  THEN COALESCE(TRY_CAST(mvx.ISS2001Value AS DECIMAL(18,4)), TRY_CAST(mvx.ISS2001UVR AS DECIMAL(18,4)))
                    ELSE 0.00
                END AS CatalogValue,
                CASE
                    WHEN cl.ResolvedManual LIKE 'ISS%' THEN mvx.ISS2001Article
                    ELSE mvx.SOATArticle
                END AS ArticleGroup,
                CASE
                    WHEN cl.ResolvedManual LIKE 'ISS%' THEN COALESCE(TRY_CAST(mvx.ISS2001UVR AS INT), TRY_CAST(mvx.SOATValue AS INT))
                    ELSE TRY_CAST(mvx.SOATValue AS INT)
                END AS SurgeryGroup
            FROM CompletedLabPanels cl
            OUTER APPLY (
                SELECT TOP (1)
                    mvl.SOATValue, mvl.SOATArticle,
                    mvl.ISS2001Value, mvl.ISS2001UVR, mvl.ISS2001Article
                FROM [dbo].[Staging_ManualValues] mvl
                WHERE mvl.CUPSCode = cl.PanelCupsCode
                  AND mvl.YearOfService <= cl.YearOfService
                ORDER BY
                    CASE WHEN mvl.YearOfService = cl.YearOfService THEN 0 ELSE 1 END ASC,
                    mvl.YearOfService DESC,
                    mvl.RecId DESC
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
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC, ce.ExceptionGuid ASC
                ) AS ExceptionPriorityRank
            FROM LabLinesWithTariffs lt
            LEFT JOIN [dbo].[ColombiaContractExceptions] ce
                ON ce.ContractGuid = lt.ResolvedContractGuid
                AND ce.Active = 1
                AND CAST(lt.CompletionDate AS DATE) >= ce.StartDate
                AND CAST(lt.CompletionDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31')
                AND ce.Ranking IN (1, 2, 3, 4, 5, 6, 7, 8)
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
                    WHEN e.ResolvedManual LIKE 'ISS%'                                   THEN 'UVR'
                    ELSE 'COP'
                END AS ValueBasis,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM AllMatchingLabExceptions e
            OUTER APPLY (
                SELECT TOP (1) up_inner.UnitValue
                FROM #UnitParameters up_inner
                WHERE up_inner.ContractType = CASE WHEN e.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up_inner.UnitCategory = CASE
                      WHEN e.CompletionDate >= '2024-01-01' AND e.ResolvedManual = 'SOAT' THEN 'UVB'
                      WHEN e.CompletionDate < '2024-01-01'  AND e.ResolvedManual = 'SOAT' THEN 'SMDLV'
                      ELSE 'UVR'
                  END
                ORDER BY
                    CASE WHEN up_inner.CalendarYear = e.YearOfService THEN 0 ELSE 1 END ASC,
                    ABS(up_inner.CalendarYear - e.YearOfService) ASC,
                    up_inner.CalendarYear DESC
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
                        WHEN c.ExceptionRanking IN (3, 5, 7, 8) THEN ISNULL(c.ExceptionPriceValue, 0.00) * c.ShiftMultiplier
                        ELSE (ISNULL(c.CatalogValue, 0.00) * c.ShiftMultiplier * c.BaseCalculatedValue * c.UnitMonetaryValue)
                    END AS DECIMAL(18,2)
                ) AS PanelLineNetAmount
            FROM CalculatedLabLines c
        )
        INSERT INTO [dbo].[PatientTransactions] (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid,
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach,
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime,
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount,
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount,
            PerItemChargeAmount, [Status], TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount, CurrentWorkflowStatus
        )
        SELECT
            @FacilityId,
            @PatientId,
            @PatientVisit,
            N'Laboratory',
            f.OrderGuid,
            f.ResolvedClaimGuid,
            NULL,
            f.ResolvedContractGuid,
            f.ExceptionGuid,
            f.Ambity,
            f.UnitMonetaryValue,
            N'Examen de Laboratorio/Patología: ' + ISNULL(f.PanelDescription, N''),
            NULL,
            NULL,
            0,
            f.RowShiftType,
            0.00,
            f.PanelCupsCode,
            NULL,
            f.CompletionDate,
            @Now,
            f.ResolvedManual,
            1,
            0.00,
            f.DiagnosisCode,
            NULL,
            f.BaseCalculatedValue,
            1.00,
            1.00,
            f.ValueBasis,
            calc.RoundedNet,
            calc.RoundedTax,
            0.00,
            calc.RoundedNet + calc.RoundedTax,
            CASE WHEN f.NoBill = 1 THEN N'Unbillable' ELSE N'Active' END,
            NEWID(),
            N'Laboratorio',
            NULL,
            NULL,
            f.PanelDescription,
            f.PanelCupsCode,
            NULL,
            NULL,
            f.EnteredBy,
            f.DateTimeOrdered,
            calc.AppliedTaxRate,
            0,
            f.PanelDescription,
            f.PanelLineNetAmount,
            N'Pending Review'
        FROM FinalLabLiquidation f
        CROSS APPLY (
            SELECT
                CASE
                    WHEN f.DiagnosisCode LIKE N'%Z41.1%' OR f.DiagnosisCode LIKE N'%Z41.8%' OR f.DiagnosisCode LIKE N'%Z41.9%'
                      OR f.DiagnosisCode LIKE N'%Z411%'  OR f.DiagnosisCode LIKE N'%Z418%'  OR f.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate
        ) tx
        CROSS APPLY (
            SELECT
                ROUND(f.PanelLineNetAmount, -2) AS RoundedNet,
                CASE WHEN tx.AppliedTaxRate > 0 THEN ROUND(f.PanelLineNetAmount * tx.AppliedTaxRate, -2) ELSE 0.00 END AS RoundedTax,
                tx.AppliedTaxRate
        ) calc;

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
                COALESCE(NULLIF(LTRIM(RTRIM(ppl.ProblemCode)), N''), @VisitDiagnosis, N'none') AS DiagnosisCode,
                ISNULL(img.NoBill, 0) AS NoBill,
                CASE
                    WHEN @ResolvedNightCharges = 0
                         OR ISNULL(amx.Ambity, '02') IN ('01', '02')
                         OR ISNULL(img.OrderPriority, N'Routine') <> N'STAT' THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN ((DATEPART(WEEKDAY, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) + @@DATEFIRST - 1) % 7) = 0 THEN 4
                    WHEN DATEPART(HOUR, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) < 7 THEN 3
                    WHEN DATEPART(HOUR, ISNULL(img.DateTimeUpdated, img.DateTimeEntered)) > 18 THEN 3
                    ELSE 2
                END AS RowShiftType,
                CAST(
                    CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s
                            WHERE s.PatientVisit = img.PatientVisit
                              AND s.Status = N'Completed'
                              AND ISNULL(s.NoBill, 0) = 0
                              AND s.IsBundle = 1
                              AND s.MaterialIncluded = 1
                              AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) >= DATEADD(HOUR, -24, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now))
                              AND ISNULL(img.DateTimeUpdated, img.DateTimeEntered) <= DATEADD(HOUR, 6, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now))
                        ) THEN 1
                        ELSE 0
                    END AS BIT
                ) AS IsImagingAbsorbedByBundle
            FROM ClinicalGeniusEhr.dbo.ImagingOrders img
            INNER JOIN ClinicalGeniusEhr.dbo.ImagingOrderItems ioi
                ON ioi.ImageOrderGuid = img.ImageOrderItemGuid
            LEFT JOIN ClinicalGeniusEhr.dbo.PatientProblemList ppl
                ON ppl.ProblemGuid = img.IndicationGuid
            LEFT JOIN #ColombianHolidays h
                ON h.HolidayDate = CAST(ISNULL(img.DateTimeUpdated, img.DateTimeEntered) AS DATE)
            OUTER APPLY (
                SELECT TOP (1) DPT.Ambity
                FROM ClinicalGeniusEhr.dbo.PatientDepartmentTracking PDT
                INNER JOIN [dbo].[Departments] DPT
                    ON DPT.DepartmentGuid = PDT.DepartmentGuid
                WHERE PDT.PatientVisit = img.PatientVisit
                  AND img.DateTimeEntered >= PDT.StartDateTime
                  AND (img.DateTimeEntered <= PDT.StopDateTime OR PDT.StopDateTime IS NULL)
                ORDER BY PDT.StartDateTime DESC
            ) amx
            WHERE img.PatientVisit = @PatientVisit
              AND img.OrderStatus = N'Completed'
              AND img.Facility = @FacilityId
              AND (
                  (@TargetClaimGuid = N'Patient' AND (img.ClaimGuid IS NULL OR img.ClaimGuid = N'Patient'))
                  OR (@TargetClaimGuid <> N'Patient' AND img.ClaimGuid = @TargetClaimGuid)
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM [dbo].[PatientTransactions] pt_locked
                  WHERE pt_locked.OrderGuid = img.ImagingOrderGuid
                    AND pt_locked.Facility = @FacilityId
                    AND pt_locked.TransactionType = N'Imaging'
                    AND pt_locked.[Status] = N'Active'
                    AND (pt_locked.DIANInvoiceBatchId IS NOT NULL OR pt_locked.RIPSBatchId IS NOT NULL)
              )
        ),
        ImagingLinesWithTariffs AS (
            SELECT
                io.*,
                CASE
                    WHEN io.ResolvedManual = 'SOAT'     THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN io.ResolvedManual LIKE 'ISS%'  THEN COALESCE(TRY_CAST(mvx.ISS2001Value AS DECIMAL(18,4)), TRY_CAST(mvx.ISS2001UVR AS DECIMAL(18,4)))
                    ELSE 0.00
                END AS CatalogValue,
                CASE
                    WHEN io.ResolvedManual LIKE 'ISS%' THEN mvx.ISS2001Article
                    ELSE mvx.SOATArticle
                END AS ArticleGroup,
                CASE
                    WHEN io.ResolvedManual LIKE 'ISS%' THEN COALESCE(TRY_CAST(mvx.ISS2001UVR AS INT), TRY_CAST(mvx.SOATValue AS INT))
                    ELSE TRY_CAST(mvx.SOATValue AS INT)
                END AS SurgeryGroup
            FROM CompletedImagingOrders io
            OUTER APPLY (
                SELECT TOP (1)
                    mvl.SOATValue, mvl.SOATArticle,
                    mvl.ISS2001Value, mvl.ISS2001UVR, mvl.ISS2001Article
                FROM [dbo].[Staging_ManualValues] mvl
                WHERE mvl.CUPSCode = io.ImagingCupsCode
                  AND mvl.YearOfService <= io.YearOfService
                ORDER BY
                    CASE WHEN mvl.YearOfService = io.YearOfService THEN 0 ELSE 1 END ASC,
                    mvl.YearOfService DESC,
                    mvl.RecId DESC
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
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC, ce.ExceptionGuid ASC
                ) AS ExceptionPriorityRank
            FROM ImagingLinesWithTariffs im
            LEFT JOIN [dbo].[ColombiaContractExceptions] ce
                ON ce.ContractGuid = im.ResolvedContractGuid
                AND ce.Active = 1
                AND CAST(im.CompletionDate AS DATE) >= ce.StartDate
                AND CAST(im.CompletionDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31')
                AND ce.Ranking IN (1, 2, 3, 4, 5, 6, 7, 8)
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
                    WHEN e.ResolvedManual LIKE 'ISS%'                                   THEN 'UVR'
                    ELSE 'COP'
                END AS ValueBasis,
                CASE
                    WHEN e.NoBill = 1 OR e.IsImagingAbsorbedByBundle = 1 THEN 1
                    ELSE ROW_NUMBER() OVER (
                        PARTITION BY
                            e.PatientVisit,
                            CAST(e.CompletionDate AS DATE),
                            CASE WHEN e.NoBill = 1 OR e.IsImagingAbsorbedByBundle = 1 THEN 1 ELSE 0 END
                        ORDER BY ISNULL(e.CatalogValue, 0.00) DESC, e.ImagingOrderGuid ASC
                    )
                END AS DailyImageRank,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM AllMatchingImagingExceptions e
            OUTER APPLY (
                SELECT TOP (1) up_inner.UnitValue
                FROM #UnitParameters up_inner
                WHERE up_inner.ContractType = CASE WHEN e.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up_inner.UnitCategory = CASE
                      WHEN e.CompletionDate >= '2024-01-01' AND e.ResolvedManual = 'SOAT' THEN 'UVB'
                      WHEN e.CompletionDate < '2024-01-01'  AND e.ResolvedManual = 'SOAT' THEN 'SMDLV'
                      ELSE 'UVR'
                  END
                ORDER BY
                    CASE WHEN up_inner.CalendarYear = e.YearOfService THEN 0 ELSE 1 END ASC,
                    ABS(up_inner.CalendarYear - e.YearOfService) ASC,
                    up_inner.CalendarYear DESC
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
                        WHEN c.ExceptionRanking IN (3, 5, 7, 8) THEN ISNULL(c.ExceptionPriceValue, 0.00) * c.ShiftMultiplier
                        ELSE (ISNULL(c.CatalogValue, 0.00) * c.ShiftMultiplier * c.BaseCalculatedValue * c.UnitMonetaryValue)
                             * CASE WHEN c.DailyImageRank > 1 THEN 0.75 ELSE 1.00 END
                    END AS DECIMAL(18,2)
                ) AS ImagingLineNetAmount
            FROM CalculatedImagingLines c
        )
        INSERT INTO [dbo].[PatientTransactions] (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid,
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach,
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime,
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount,
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount,
            PerItemChargeAmount, [Status], TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount, CurrentWorkflowStatus
        )
        SELECT
            @FacilityId,
            @PatientId,
            @PatientVisit,
            N'Imaging',
            f.ImagingOrderGuid,
            f.ResolvedClaimGuid,
            NULL,
            f.ResolvedContractGuid,
            f.ExceptionGuid,
            f.Ambity,
            f.UnitMonetaryValue,
            N'Procedimiento de Imagenología: ' + ISNULL(f.ImagingDescription, N''),
            NULL,
            NULL,
            0,
            f.RowShiftType,
            0.00,
            f.ImagingCupsCode,
            NULL,
            f.CompletionDate,
            @Now,
            f.ResolvedManual,
            1,
            0.00,
            f.DiagnosisCode,
            NULL,
            f.BaseCalculatedValue,
            1.00,
            1.00,
            f.ValueBasis,
            calc.RoundedNet,
            calc.RoundedTax,
            0.00,
            calc.RoundedNet + calc.RoundedTax,
            CASE WHEN f.NoBill = 1 THEN N'Unbillable' ELSE N'Active' END,
            NEWID(),
            N'Imagen',
            NULL,
            NULL,
            f.ImagingDescription,
            f.ImagingCupsCode,
            NULL,
            NULL,
            f.EnteredBy,
            f.DateTimeEntered,
            calc.AppliedTaxRate,
            0,
            f.ImagingDescription,
            f.ImagingLineNetAmount,
            N'Pending Review'
        FROM FinalImagingLiquidation f
        CROSS APPLY (
            SELECT
                CASE
                    WHEN f.DiagnosisCode LIKE N'%Z41.1%' OR f.DiagnosisCode LIKE N'%Z41.8%' OR f.DiagnosisCode LIKE N'%Z41.9%'
                      OR f.DiagnosisCode LIKE N'%Z411%'  OR f.DiagnosisCode LIKE N'%Z418%'  OR f.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate
        ) tx
        CROSS APPLY (
            SELECT
                ROUND(f.ImagingLineNetAmount, -2) AS RoundedNet,
                CASE WHEN tx.AppliedTaxRate > 0 THEN ROUND(f.ImagingLineNetAmount * tx.AppliedTaxRate, -2) ELSE 0.00 END AS RoundedTax,
                tx.AppliedTaxRate
        ) calc;


        -- ##########################################################################################
        -- ##  MODULE 3: MEDICATIONS (with Resolution 948 Ranking 9 DispensingValue)
        -- ##########################################################################################

        IF @TargetClaimGuid <> N'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.MedicationAdministrationSchedule WITH (ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND Status = N'Completed'
              AND ClaimGuid IS NULL;
        END

        UPDATE [dbo].[PatientTransactions] WITH (ROWLOCK, UPDLOCK)
        SET [Status] = N'Canceled',
            DateTimeLastUpdated = @Now,
            LastUpdatedBy = N'PricingEngine_Medications'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = N'Medication'
          AND [Status] IN (N'Active', N'Unbillable')
          AND DIANInvoiceBatchId IS NULL
          AND RIPSBatchId IS NULL
          AND (
              (@TargetClaimGuid = N'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = N'Patient'))
              OR (@TargetClaimGuid <> N'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

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
                itm.DrugNDC,
                mar.MedicationName,
                mar.ActualDoseGiven,
                mar.QuantityUnit,
                mar.Facility,
                ISNULL(amx.Ambity, '01') AS Ambity,
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                ISNULL(mar.NoBill, 0) AS NoBill,
                COALESCE(NULLIF(LTRIM(RTRIM(pmd.AssociatedDiagnosisICDN)), N''), @VisitDiagnosis, N'none') AS DiagnosisCode,
                ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) AS TargetDate,
                YEAR(ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) AS YearOfService,
                CAST(ISNULL(itm.BasePrice, 0.00) AS DECIMAL(18,2)) AS FormularyBasePrice,
                CAST(ISNULL(itm.Cost, 0.00) AS DECIMAL(18,2)) AS FormularyUnitCost,
                ISNULL(surg.IsBundledInPackage, CAST(0 AS BIT)) AS IsBundledInPackage,
                surg.SurgeryGuid,
                CASE
                    WHEN @ResolvedNightCharges = 0 OR ISNULL(amx.Ambity, '01') IN ('01', '02') THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN ((DATEPART(WEEKDAY, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) + @@DATEFIRST - 1) % 7) = 0 THEN 4
                    WHEN DATEPART(HOUR, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) < 7 THEN 3
                    WHEN DATEPART(HOUR, ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered)) > 18 THEN 3
                    ELSE 2
                END AS RowShiftType
            FROM ClinicalGeniusEhr.dbo.MedicationAdministrationSchedule mar
            INNER JOIN ClinicalGeniusEhr.dbo.PatientMeds pmd
                ON pmd.MedsGuid = mar.MedOrderId
            INNER JOIN [dbo].[ItemMaster] itm
                ON itm.ItemMasterGuid = pmd.ItemGuid
            LEFT JOIN #ColombianHolidays h
                ON h.HolidayDate = CAST(ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) AS DATE)
            OUTER APPLY (
                SELECT TOP (1) DPT.Ambity
                FROM ClinicalGeniusEhr.dbo.PatientDepartmentTracking PDT
                INNER JOIN [dbo].[Departments] DPT
                    ON DPT.DepartmentGuid = PDT.DepartmentGuid
                WHERE PDT.PatientVisit = @PatientVisit
                  AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) >= PDT.StartDateTime
                  AND (ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) <= PDT.StopDateTime OR PDT.StopDateTime IS NULL)
                ORDER BY PDT.StartDateTime DESC
            ) amx
            OUTER APPLY (
                -- Deduplicated TOP (1) surgery lookup prevents row multiplication when multiple surgeries exist
                SELECT TOP (1)
                    s.SurgeryGuid,
                    CAST(CASE WHEN s.IsBundle = 1 AND s.MedicationIncluded = 1 THEN 1 ELSE 0 END AS BIT) AS IsBundledInPackage
                FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s
                WHERE s.PatientVisit = mar.PatientVisit
                  AND s.Status = N'Completed'
                  AND ISNULL(s.NoBill, 0) = 0
                  AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) >= DATEADD(HOUR, -24, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now))
                  AND ISNULL(mar.DateTimeAdministered, mar.DateTimeEntered) <= DATEADD(HOUR, 6, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now))
                ORDER BY
                    CASE WHEN s.IsBundle = 1 AND s.MedicationIncluded = 1 THEN 0 ELSE 1 END ASC,
                    COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now) DESC
            ) surg
            WHERE mar.PatientVisit = @PatientVisit
              AND mar.Status = N'Completed'
              AND mar.Facility = @FacilityId
              AND mar.ActualDoseGiven > 0
              AND (
                  (@TargetClaimGuid = N'Patient' AND (mar.ClaimGuid IS NULL OR mar.ClaimGuid = N'Patient'))
                  OR (@TargetClaimGuid <> N'Patient' AND mar.ClaimGuid = @TargetClaimGuid)
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM [dbo].[PatientTransactions] pt_locked
                  WHERE pt_locked.OrderGuid = mar.MedSchedGuid
                    AND pt_locked.Facility = @FacilityId
                    AND pt_locked.TransactionType = N'Medication'
                    AND pt_locked.[Status] = N'Active'
                    AND (pt_locked.DIANInvoiceBatchId IS NOT NULL OR pt_locked.RIPSBatchId IS NOT NULL)
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
                    -- Partition strictly by MedSchedGuid so simultaneous doses of the same CUM are never dropped
                    PARTITION BY m.MedSchedGuid
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC, ce.ExceptionGuid ASC
                ) AS ExceptionPriorityRank
            FROM ActiveMedicationList m
            LEFT JOIN [dbo].[ColombiaContractExceptions] ce
                ON ce.ContractGuid = @ResolvedContractGuid
                AND ce.Active = 1
                AND CAST(m.TargetDate AS DATE) >= ce.StartDate
                AND CAST(m.TargetDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31')
                AND ce.Ranking IN (3, 4, 5, 6, 7, 8)
                AND ce.CUPSCode = m.MedicationCode
                AND (ce.ShiftType = 1 OR ce.ShiftType = m.RowShiftType)
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = m.Ambity)
        ),
        CalculatedMedicationLines AS (
            SELECT
                e.*,
                CAST(1 + (@ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4)) AS BaseCalculatedValue,
                CAST(
                    CASE
                        WHEN e.NoBill = 1 OR e.IsBundledInPackage = 1 THEN 0.00
                        WHEN e.ExceptionRanking IN (3, 5, 7, 8) THEN (e.ActualDoseGiven * ISNULL(e.ExceptionPriceValue, 0.00))
                        ELSE (e.ActualDoseGiven * e.FormularyBasePrice) * CAST(1 + (@ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4))
                    END AS DECIMAL(18,2)
                ) AS MedicationBaseTotal,
                CAST(
                    CASE
                        WHEN e.NoBill = 1 OR e.IsBundledInPackage = 1 THEN 0.00
                        WHEN ISNULL(disp.PriceValue, 0.00) > 0.00 THEN (e.ActualDoseGiven * disp.PriceValue)
                        WHEN ISNULL(disp.PriceModifier, 0.00) > 0.00
                        THEN (
                            CASE
                                WHEN e.ExceptionRanking IN (3, 5, 7, 8) THEN (e.ActualDoseGiven * ISNULL(e.ExceptionPriceValue, 0.00))
                                ELSE (e.ActualDoseGiven * e.FormularyBasePrice) * CAST(1 + (@ResolvedAdjustmentPct / 100.00) + (e.PriceModifier / 100.00) AS DECIMAL(10,4))
                            END
                        ) * (disp.PriceModifier / 100.00)
                        ELSE 0.00
                    END AS DECIMAL(18,2)
                ) AS DispensingMarkup
            FROM AllMatchingMedicationExceptions e
            OUTER APPLY (
                -- Resolution 948: Ranking 9 Dispensing Fee lookup mapped via ItemMaster.DrugNDC -> ExceptionType
                SELECT TOP (1)
                    ce_disp.PriceValue,
                    ce_disp.PriceModifier
                FROM [dbo].[ColombiaContractExceptions] ce_disp
                WHERE ce_disp.ContractGuid = @ResolvedContractGuid
                  AND ce_disp.Active = 1
                  AND ce_disp.Ranking = 9
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), e.DrugNDC))), N'') IS NOT NULL
                  AND LTRIM(RTRIM(CONVERT(NVARCHAR(50), ce_disp.ExceptionType))) = LTRIM(RTRIM(CONVERT(NVARCHAR(50), e.DrugNDC)))
                  AND CAST(e.TargetDate AS DATE) >= ce_disp.StartDate
                  AND CAST(e.TargetDate AS DATE) <= ISNULL(ce_disp.EndDate, '9999-12-31')
                  AND (ce_disp.ShiftType = 1 OR ce_disp.ShiftType = e.RowShiftType)
                  AND (ce_disp.ServiceGroup = '00' OR ce_disp.ServiceGroup = e.Ambity)
                ORDER BY ABS(ISNULL(ce_disp.PriceValue, 0.00)) DESC, ce_disp.StartDate DESC, ce_disp.ExceptionGuid ASC
            ) disp
            WHERE e.ExceptionPriorityRank = 1
        )
        INSERT INTO [dbo].[PatientTransactions] (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid,
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach,
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime,
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount,
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount,
            PerItemChargeAmount, [Status], TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,
            CurrentWorkflowStatus, DispensingValue
        )
        SELECT
            @FacilityId,
            @PatientId,
            @PatientVisit,
            N'Medication',
            f.MedSchedGuid,
            f.ResolvedClaimGuid,
            f.SurgeryGuid,
            @ResolvedContractGuid,
            f.ExceptionGuid,
            ISNULL(f.Ambity, '02'),
            f.FormularyBasePrice,
            f.MedicationName,
            NULL,
            NULL,
            0,
            f.RowShiftType,
            0.00,
            f.MedicationCode,
            f.MedicationCode,
            f.TargetDate,
            @Now,
            @ResolvedManual,
            f.ActualDoseGiven,
            f.FormularyUnitCost,
            f.DiagnosisCode,
            f.QuantityUnit,
            f.BaseCalculatedValue,
            1.00,
            1.00,
            'COP',
            calc.RoundedInclusiveNet,
            calc.RoundedTax,
            0.00,
            calc.RoundedInclusiveNet + calc.RoundedTax,
            CASE WHEN f.NoBill = 1 THEN N'Unbillable' ELSE N'Active' END,
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
            calc.AppliedTaxRate,
            0,
            f.MedicationName,
            f.MedicationBaseTotal + f.DispensingMarkup,
            N'Pending Review',
            calc.RoundedDispensing
        FROM CalculatedMedicationLines f
        CROSS APPLY (
            SELECT
                CASE
                    WHEN f.DiagnosisCode LIKE N'%Z41.1%' OR f.DiagnosisCode LIKE N'%Z41.8%' OR f.DiagnosisCode LIKE N'%Z41.9%'
                      OR f.DiagnosisCode LIKE N'%Z411%'  OR f.DiagnosisCode LIKE N'%Z418%'  OR f.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate,
                ROUND(f.MedicationBaseTotal, -2) AS RoundedBase,
                ROUND(f.DispensingMarkup, -2) AS RoundedDispensing
        ) tx
        CROSS APPLY (
            SELECT
                (tx.RoundedBase + tx.RoundedDispensing) AS RoundedInclusiveNet,
                CASE
                    WHEN tx.AppliedTaxRate > 0 THEN ROUND((tx.RoundedBase + tx.RoundedDispensing) * tx.AppliedTaxRate, -2)
                    ELSE 0.00
                END AS RoundedTax,
                tx.AppliedTaxRate,
                tx.RoundedDispensing
        ) calc;


        -- ##########################################################################################
        -- ##  MODULE 4: PROCEDURES
        -- ##########################################################################################

        IF @TargetClaimGuid <> N'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.PatientProcedures WITH (ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND ProcedureStatus = N'Active'
              AND ClaimGuid IS NULL;
        END

        UPDATE [dbo].[PatientTransactions] WITH (ROWLOCK, UPDLOCK)
        SET [Status] = N'Canceled',
            DateTimeLastUpdated = @Now,
            LastUpdatedBy = N'PricingEngine_Procedures'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = N'Procedure'
          AND SurgeryGuid IS NULL
          AND [Status] IN (N'Active', N'Unbillable')
          AND DIANInvoiceBatchId IS NULL
          AND RIPSBatchId IS NULL
          AND (
              (@TargetClaimGuid = N'Patient' AND (ClaimGuid IS NULL OR ClaimGuid = N'Patient'))
              OR (@TargetClaimGuid <> N'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

        ;WITH ProcedureList AS (
            SELECT
                pp.ProcedureGuid,
                pp.PatientVisit,
                ppa.RVSCode AS ProcedureCode,
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
                COALESCE(NULLIF(LTRIM(RTRIM(ppl.ProblemCode)), N''), @VisitDiagnosis, N'none') AS DiagnosisCode,
                ISNULL(pp.NoBill, 0) AS IsUnbillable,
                ISNULL(amx.Ambity, '01') AS Ambity,
                CASE
                    WHEN @ResolvedManual = 'SOAT'     THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN @ResolvedManual LIKE 'ISS%'  THEN COALESCE(TRY_CAST(mvx.ISS2001Value AS DECIMAL(18,4)), TRY_CAST(mvx.ISS2001UVR AS DECIMAL(18,4)))
                    ELSE 0.00
                END AS CatalogValue,
                CASE
                    WHEN @ResolvedManual = 'SOAT'     THEN TRY_CAST(mvx.SOATValue AS INT)
                    WHEN @ResolvedManual LIKE 'ISS%'  THEN COALESCE(TRY_CAST(mvx.ISS2001UVR AS INT), TRY_CAST(mvx.SOATValue AS INT))
                    ELSE NULL
                END AS SurgeryGroup,
                CASE
                    WHEN @ResolvedManual = 'SOAT'     THEN mvx.SOATArticle
                    WHEN @ResolvedManual LIKE 'ISS%'  THEN mvx.ISS2001Article
                    ELSE NULL
                END AS ArticleGroup,
                ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS TargetDate,
                YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) AS YearOfService,
                CASE
                    WHEN @ResolvedNightCharges = 0
                         OR ISNULL(amx.Ambity, '01') IN ('01', '02')
                         OR ISNULL(pp.ProcedurePriority, N'Routine') <> N'STAT' THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN ((DATEPART(WEEKDAY, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) + @@DATEFIRST - 1) % 7) = 0 THEN 4
                    WHEN DATEPART(HOUR, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) < 7 THEN 3
                    WHEN DATEPART(HOUR, ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) > 18 THEN 3
                    ELSE 2
                END AS RowShiftType,
                CAST(
                    CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s
                            WHERE s.PatientVisit = pp.PatientVisit
                              AND s.Status = N'Completed'
                              AND ISNULL(s.NoBill, 0) = 0
                              AND s.IsBundle = 1
                              AND s.MaterialIncluded = 1
                              AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) >= DATEADD(HOUR, -24, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now))
                              AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) <= DATEADD(HOUR, 6, COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now))
                        ) THEN 1
                        ELSE 0
                    END AS BIT
                ) AS IsProcedureAbsorbedByBundle
            FROM ClinicalGeniusEhr.dbo.PatientProcedures pp
            INNER JOIN ClinicalGeniusEhr.dbo.PatientProcedureAdministration ppa
                ON ppa.ProcedureGuid = pp.ProcedureCode
            LEFT JOIN ClinicalGeniusEhr.dbo.PatientProblemList ppl
                ON ppl.ProblemGuid = pp.IndicationGuid
            LEFT JOIN [dbo].[ItemMaster] itm
                ON itm.ItemMasterGuid = pp.ProcedureCode
            LEFT JOIN #ColombianHolidays h
                ON h.HolidayDate = CAST(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS DATE)
            OUTER APPLY (
                SELECT TOP (1) DPT.Ambity
                FROM ClinicalGeniusEhr.dbo.PatientDepartmentTracking PDT
                INNER JOIN [dbo].[Departments] DPT
                    ON DPT.DepartmentGuid = PDT.DepartmentGuid
                WHERE PDT.PatientVisit = @PatientVisit
                  AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) >= PDT.StartDateTime
                  AND (ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) <= PDT.StopDateTime OR PDT.StopDateTime IS NULL)
                ORDER BY PDT.StartDateTime DESC
            ) amx
            OUTER APPLY (
                SELECT TOP (1)
                    mvl.SOATValue, mvl.SOATArticle,
                    mvl.ISS2001Value, mvl.ISS2001UVR, mvl.ISS2001Article
                FROM [dbo].[Staging_ManualValues] mvl
                WHERE mvl.CUPSCode = ppa.RVSCode
                  AND mvl.YearOfService <= YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered))
                ORDER BY
                    CASE WHEN mvl.YearOfService = YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered)) THEN 0 ELSE 1 END ASC,
                    mvl.YearOfService DESC,
                    mvl.RecId DESC
            ) mvx
            WHERE pp.PatientVisit = @PatientVisit
              AND pp.ProcedureStatus = N'Active'
              AND pp.Facility = @FacilityId
              AND (
                  (@TargetClaimGuid = N'Patient' AND (pp.ClaimGuid IS NULL OR pp.ClaimGuid = N'Patient'))
                  OR (@TargetClaimGuid <> N'Patient' AND pp.ClaimGuid = @TargetClaimGuid)
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM [dbo].[PatientTransactions] pt_locked
                  WHERE pt_locked.OrderGuid = pp.ProcedureGuid
                    AND pt_locked.Facility = @FacilityId
                    AND pt_locked.TransactionType = N'Procedure'
                    AND pt_locked.[Status] = N'Active'
                    AND (pt_locked.DIANInvoiceBatchId IS NOT NULL OR pt_locked.RIPSBatchId IS NOT NULL)
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
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC, ce.ExceptionGuid ASC
                ) AS ExceptionPriorityRank
            FROM ProcedureList opl
            LEFT JOIN [dbo].[ColombiaContractExceptions] ce
                ON ce.ContractGuid = opl.ResolvedContractGuid
                AND ce.Active = 1
                AND CAST(opl.TargetDate AS DATE) >= ce.StartDate
                AND CAST(opl.TargetDate AS DATE) <= ISNULL(ce.EndDate, '9999-12-31')
                AND ce.Ranking IN (1, 2, 3, 4, 5, 6, 7, 8)
                AND (ce.Ranking <> 1 OR ce.ExceptionType = opl.ArticleGroup)
                AND (ce.Ranking <> 2 OR ce.SurgeryGrp = opl.SurgeryGroup)
                AND (ce.Ranking NOT IN (3, 4, 5, 6, 7, 8) OR ce.CupsCode = opl.ProcedureCode)
                AND (ce.ShiftType = 1 OR ce.ShiftType = opl.RowShiftType)
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = opl.Ambity OR ce.ServiceGroup = opl.ServiceGroup)
        ),
        AppliedExceptions AS (
            SELECT
                apx.*,
                ISNULL(apx.ExceptionPriceModifier, 0.00) AS PriceModifier,
                ISNULL(apx.ExceptionPriceValue, 0.00) AS PriceValue
            FROM AllMatchingProcedureExceptions apx
            WHERE apx.ExceptionPriorityRank = 1
        ),
        BaseUnits AS (
            SELECT
                pe.*,
                CAST(
                    CASE
                        WHEN pe.IsUnbillable = 1 THEN 0.00
                        ELSE (1 + (pe.ResolvedAdjustmentPct / 100.00) + (pe.PriceModifier / 100.00))
                    END AS DECIMAL(10,4)
                ) AS BaseCalculatedValue,
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
                CASE
                    WHEN b.IsUnbillable = 1 OR b.IsProcedureAbsorbedByBundle = 1 THEN 1
                    ELSE ROW_NUMBER() OVER (
                        PARTITION BY
                            b.PatientVisit,
                            CAST(b.TargetDate AS DATE),
                            CASE WHEN b.IsUnbillable = 1 OR b.IsProcedureAbsorbedByBundle = 1 THEN 1 ELSE 0 END
                        ORDER BY b.RawCatalogUnits DESC, b.ProcedureGuid ASC
                    )
                END AS DailyProcedureRank,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM BaseUnits b
            OUTER APPLY (
                SELECT TOP (1) up_inner.UnitValue
                FROM #UnitParameters up_inner
                WHERE up_inner.ContractType = CASE WHEN b.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up_inner.UnitCategory = CASE
                      WHEN b.TargetDate >= '2024-01-01' AND b.ResolvedManual = 'SOAT' THEN 'UVB'
                      WHEN b.TargetDate < '2024-01-01'  AND b.ResolvedManual = 'SOAT' THEN 'SMDLV'
                      ELSE 'UVR'
                  END
                ORDER BY
                    CASE WHEN up_inner.CalendarYear = b.YearOfService THEN 0 ELSE 1 END ASC,
                    ABS(up_inner.CalendarYear - b.YearOfService) ASC,
                    up_inner.CalendarYear DESC
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
                        WHEN o.ResolvedManual LIKE 'ISS%' AND o.RawCatalogUnits > 3000 THEN
                            o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue * CASE WHEN o.DailyProcedureRank > 1 THEN 0.50 ELSE 1.00 END
                        ELSE (o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue * o.UnitMonetaryValue)
                             * CASE WHEN o.DailyProcedureRank > 1 THEN 0.50 ELSE 1.00 END
                    END AS DECIMAL(18,2)
                ) AS LineTotal
            FROM FinalShiftAdjustments o
        )
        INSERT INTO [dbo].[PatientTransactions] (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid,
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach,
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime,
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount,
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount,
            PerItemChargeAmount, [Status], TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount, CurrentWorkflowStatus
        )
        SELECT
            @FacilityId,
            @PatientId,
            @PatientVisit,
            N'Procedure',
            f.ProcedureGuid,
            f.ResolvedClaimGuid,
            NULL,
            f.ResolvedContractGuid,
            f.ExceptionGuid,
            ISNULL(f.Ambity, '01'),
            f.UnitMonetaryValue,
            f.ProcedureDescription,
            NULL,
            NULL,
            0,
            f.RowShiftType,
            0.00,
            f.ProcedureCode,
            NULL,
            f.TargetDate,
            @Now,
            f.ResolvedManual,
            1,
            1,
            f.DiagnosisCode,
            f.RawCatalogUnits,
            f.BaseCalculatedValue,
            1.00,
            f.ShiftMultiplier,
            f.ValueBasis,
            calc.RoundedNet,
            calc.RoundedTax,
            0.00,
            calc.RoundedNet + calc.RoundedTax,
            CASE WHEN f.IsUnbillable = 1 THEN N'Unbillable' ELSE N'Active' END,
            NEWID(),
            N'Unidad',
            f.ProcedureObjective,
            f.ItemMasterGuid,
            f.ProcedureDescription,
            ISNULL(f.ItemNumber, f.ProcedureCode),
            f.Type,
            f.Category,
            f.EnteredBy,
            f.DateTimeEntered,
            calc.AppliedTaxRate,
            0,
            f.ProcedureDescription,
            f.LineTotal,
            N'Pending Review'
        FROM CalculatedLines f
        CROSS APPLY (
            SELECT
                CASE
                    WHEN f.DiagnosisCode LIKE N'%Z41.1%' OR f.DiagnosisCode LIKE N'%Z41.8%' OR f.DiagnosisCode LIKE N'%Z41.9%'
                      OR f.DiagnosisCode LIKE N'%Z411%'  OR f.DiagnosisCode LIKE N'%Z418%'  OR f.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate
        ) tx
        CROSS APPLY (
            SELECT
                ROUND(f.LineTotal, -2) AS RoundedNet,
                CASE WHEN tx.AppliedTaxRate > 0 THEN ROUND(f.LineTotal * tx.AppliedTaxRate, -2) ELSE 0.00 END AS RoundedTax,
                tx.AppliedTaxRate
        ) calc;


        -- ##########################################################################################
        -- ##  MODULE 5: SURGERIES
        -- ##########################################################################################

        IF @TargetClaimGuid <> N'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.ScheduledSurgeries WITH (ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND Status = N'Completed'
              AND ClaimGuid IS NULL;
        END

        UPDATE pt
        SET pt.[Status] = N'Canceled',
            pt.DateTimeLastUpdated = @Now,
            pt.LastUpdatedBy = N'PricingEngine_Surgeries'
        FROM [dbo].[PatientTransactions] pt WITH (ROWLOCK, UPDLOCK)
        LEFT JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s
            ON s.SurgeryGuid = pt.SurgeryGuid
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Facility = @FacilityId
          AND pt.TransactionType IN (N'Surgery', N'RoomRights', N'Supplies', N'Honorary', N'BundleMaster', N'Materials')
          AND pt.[Status] IN (N'Active', N'Unbillable')
          AND pt.DIANInvoiceBatchId IS NULL
          AND pt.RIPSBatchId IS NULL
          AND (
              pt.TransactionType <> N'Honorary'
              OR (pt.TransactionType = N'Honorary' AND ISNULL(pt.CurrentWorkflowStatus, N'Pending Review') = N'Pending Review')
              OR ISNULL(s.NoBill, 0) = 1
          )
          AND (
              (@TargetClaimGuid = N'Patient' AND (pt.ClaimGuid IS NULL OR pt.ClaimGuid = N'Patient'))
              OR (@TargetClaimGuid <> N'Patient' AND pt.ClaimGuid = @TargetClaimGuid)
          );

        -- 5.4a Surgery Context
        SELECT
            s.SurgeryGuid,
            COALESCE(s.DateTimePerformed, s.DateTimeCompleted, s.DateTimeScheduled, @Now) AS DateTimePerformed,
            CAST(ISNULL(s.IsBundle, 0) AS BIT) AS IsBundle,
            s.BundleDescription,
            CAST(ISNULL(s.BundlePrice, 0.00) AS DECIMAL(18,2)) AS BundlePrice,
            CAST(ISNULL(s.SurgeonIncluded, 0) AS BIT) AS SurgeonIncluded,
            CAST(ISNULL(s.AnesthesiologistIncluded, 0) AS BIT) AS AnesthesiologistIncluded,
            CAST(ISNULL(s.AssistantIncluded, 0) AS BIT) AS AssistantIncluded,
            CAST(ISNULL(s.RoomIncluded, 0) AS BIT) AS RoomIncluded,
            CAST(ISNULL(s.MaterialIncluded, 0) AS BIT) AS MaterialIncluded,
            CAST(ISNULL(s.MedicationIncluded, 0) AS BIT) AS MedicationIncluded,
            ISNULL(NULLIF(LTRIM(RTRIM(s.ClaimGuid)), N''), @ResolvedClaimGuid) AS ResolvedClaimGuid,
            ISNULL(contract_info.ContractGuid, @ResolvedContractGuid) AS ResolvedContractGuid,
            ISNULL(NULLIF(LTRIM(RTRIM(contract_info.EntityCode)), ''), @ResolvedManual) AS ResolvedManual,
            ISNULL(contract_info.AdjustmentPct, @ResolvedAdjustmentPct) AS ResolvedAdjustmentPct,
            ISNULL(contract_info.NightCharges, @ResolvedNightCharges) AS ResolvedNightCharges,
            COALESCE(NULLIF(LTRIM(RTRIM(s.ConfirmedDiagnosisCode)), N''), @VisitDiagnosis, N'none') AS DiagnosisCode,
            ISNULL(s.Priority, N'Electiva') AS Priority
        INTO #SurgeryContext
        FROM ClinicalGeniusEhr.dbo.ScheduledSurgeries s
        OUTER APPLY (
            SELECT TOP (1)
                isc_s.ContractGuid,
                isc_s.EntityCode,
                isc_s.AdjustmentPct,
                isc_s.NightCharges
            FROM [dbo].[PayerClaims] pyc_s
            INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy_s
                ON ppy_s.PatientPayerGuid = pyc_s.PayerGuid
            INNER JOIN [dbo].[InsurancePlans] isp_s
                ON isp_s.PlanGuid = ppy_s.PayerPlan
            INNER JOIN [dbo].[InsuranceContracts] isc_s
                ON isc_s.ContractGuid = isp_s.ContractGuid
            WHERE pyc_s.ClaimGuid = ISNULL(NULLIF(LTRIM(RTRIM(s.ClaimGuid)), N''), @ResolvedClaimGuid)
              AND pyc_s.Facility = @FacilityId
        ) contract_info
        WHERE s.PatientVisit = @PatientVisit
          AND s.Status = N'Completed'
          AND s.Facility = @FacilityId
          AND ISNULL(s.NoBill, 0) = 0
          AND (
              (@TargetClaimGuid = N'Patient' AND (s.ClaimGuid IS NULL OR s.ClaimGuid = N'Patient'))
              OR (@TargetClaimGuid <> N'Patient' AND s.ClaimGuid = @TargetClaimGuid)
          );

        -- 5.4b Surgical Execution Pipeline Matrix
        ;WITH MasterSoatGroupsArray AS (
            SELECT SurgicalGroup, SubtypeCode, CAST(BaseUnits AS DECIMAL(18,2)) AS BaseUnits
            FROM (VALUES
                  (1, 1, 1.14),  (1, 2, 0.81),  (1, 3, 0.35),  (1, 4, 1.34),  (1, 5, 0.82)
                , (2, 1, 1.63),  (2, 2, 1.11),  (2, 3, 0.49),  (2, 4, 2.14),  (2, 5, 1.30)
                , (3, 1, 2.37),  (3, 2, 1.54),  (3, 3, 0.69),  (3, 4, 3.19),  (3, 5, 1.83)
                , (4, 1, 3.01),  (4, 2, 1.98),  (4, 3, 0.84),  (4, 4, 4.09),  (4, 5, 2.45)
                , (5, 1, 3.73),  (5, 2, 2.41),  (5, 3, 1.01),  (5, 4, 4.70),  (5, 5, 3.42)
                , (6, 1, 4.67),  (6, 2, 2.87),  (6, 3, 1.25),  (6, 4, 6.00),  (6, 5, 4.07)
                , (7, 1, 5.66),  (7, 2, 3.36),  (7, 3, 1.51),  (7, 4, 6.94),  (7, 5, 4.70)
                , (8, 1, 6.75),  (8, 2, 3.90),  (8, 3, 1.80),  (8, 4, 7.97),  (8, 5, 5.37)
                , (9, 1, 8.01),  (9, 2, 4.41),  (9, 3, 2.13),  (9, 4, 9.07),  (9, 5, 6.07)
                , (10, 1, 9.53), (10, 2, 5.03), (10, 3, 2.53), (10, 4, 11.23), (10, 5, 7.15)
                , (11, 1, 11.45),(11, 2, 5.75), (11, 3, 3.03), (11, 4, 13.68), (11, 5, 8.52)
                , (12, 1, 13.91),(12, 2, 6.64), (12, 3, 3.67), (12, 4, 16.92), (12, 5, 10.38)
                , (13, 1, 17.14),(13, 2, 7.76), (13, 3, 4.51), (13, 4, 21.04), (13, 5, 12.87)
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
                NULLIF(LTRIM(RTRIM(sp.SurgeonId)), N'') AS SurgeonId,
                NULLIF(LTRIM(RTRIM(sp.Anesthesiologist)), N'') AS Anesthesiologist,
                NULLIF(LTRIM(RTRIM(sp.Assistant1)), N'') AS SurgeonId2,
                NULLIF(LTRIM(RTRIM(sp.Assistant2)), N'') AS SurgeonId3,
                ISNULL(sp.IncisionNumber, 1) AS IncisionNumber,
                sp.IsPrimary AS IsClinicalPrimary,
                ISNULL(sp.NoBill, 0) AS NoBill,
                YEAR(scx.DateTimePerformed) AS YearOfService,
                sp.EnteredBy,
                sp.ProcedureGuid,
                itm.ItemMasterGuid,
                itm.Type,
                itm.Category,
                itm.ItemNumber,
                pa.ProcedureDescription,
                pa.RVSCode AS CUPSCode,
                actual_prim.PrimaryPerformedCupsCode AS BundleCupsCode,
                CASE
                    WHEN scx.ResolvedNightCharges = 0 OR scx.Priority <> N'Urgente' THEN 2
                    WHEN h.HolidayDate IS NOT NULL THEN 4
                    WHEN ((DATEPART(WEEKDAY, scx.DateTimePerformed) + @@DATEFIRST - 1) % 7) = 0 THEN 4
                    WHEN DATEPART(HOUR, scx.DateTimePerformed) < 7 THEN 3
                    WHEN DATEPART(HOUR, scx.DateTimePerformed) > 18 THEN 3
                    ELSE 2
                END AS RowShiftType
            FROM #SurgeryContext scx
            INNER JOIN [dbo].[SurgeryProcedures] sp
                ON sp.SurgeryGuid = scx.SurgeryGuid AND sp.Active = 1
            INNER JOIN [dbo].[ItemMaster] itm
                ON itm.ItemMasterGuid = sp.ProcedureGuid
            INNER JOIN ClinicalGeniusEhr.dbo.PatientProcedureAdministration pa
                ON pa.ProcedureGuid = sp.ProcedureGuid
            LEFT JOIN #ColombianHolidays h
                ON h.HolidayDate = CAST(scx.DateTimePerformed AS DATE)
            OUTER APPLY (
                SELECT TOP (1) pai_prim.RVSCode AS PrimaryPerformedCupsCode
                FROM [dbo].[SurgeryProcedures] sp_prim
                INNER JOIN ClinicalGeniusEhr.dbo.PatientProcedureAdministration pai_prim
                    ON sp_prim.ProcedureGuid = pai_prim.ProcedureGuid
                WHERE sp_prim.SurgeryGuid = scx.SurgeryGuid
                  AND sp_prim.Active = 1
                ORDER BY sp_prim.IsPrimary DESC, sp_prim.IncisionNumber ASC, sp_prim.SurgeryProcedureGuid ASC
            ) actual_prim
        ),
        ProceduresWithCodes AS (
            SELECT
                rp.*,
                CASE
                    WHEN rp.ResolvedManual = 'SOAT'     THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN rp.ResolvedManual LIKE 'ISS%'  THEN COALESCE(TRY_CAST(mvx.ISS2001Value AS DECIMAL(18,4)), TRY_CAST(mvx.ISS2001UVR AS DECIMAL(18,4)))
                    ELSE 0.00
                END AS ManualValue,
                CASE
                    WHEN rp.ResolvedManual = 'SOAT'     THEN TRY_CAST(mvx.SOATValue AS INT)
                    WHEN rp.ResolvedManual LIKE 'ISS%'  THEN COALESCE(TRY_CAST(mvx.ISS2001UVR AS INT), TRY_CAST(mvx.SOATValue AS INT))
                    ELSE NULL
                END AS SurgeryGroup,
                CASE
                    WHEN rp.ResolvedManual = 'SOAT'     THEN mvx.SOATArticle
                    WHEN rp.ResolvedManual LIKE 'ISS%'  THEN mvx.ISS2001Article
                    ELSE NULL
                END AS ArticleGroup
            FROM RawProcedureEntries rp
            OUTER APPLY (
                SELECT TOP (1)
                    mvl.SOATValue, mvl.SOATArticle,
                    mvl.ISS2001Value, mvl.ISS2001UVR, mvl.ISS2001Article
                FROM [dbo].[Staging_ManualValues] mvl
                WHERE mvl.CUPSCode = rp.CUPSCode
                  AND mvl.YearOfService <= rp.YearOfService
                ORDER BY
                    CASE WHEN mvl.YearOfService = rp.YearOfService THEN 0 ELSE 1 END ASC,
                    mvl.YearOfService DESC,
                    mvl.RecId DESC
            ) mvx
        ),
        IncisionValuation AS (
            SELECT
                pw.*,
                ROW_NUMBER() OVER (
                    PARTITION BY pw.SurgeryGuid, pw.IncisionNumber
                    ORDER BY
                        pw.NoBill ASC,
                        CASE WHEN pw.ResolvedManual = 'SOAT' THEN ISNULL(pw.SurgeryGroup, 0) ELSE 0 END DESC,
                        ISNULL(pw.ManualValue, 0.00) DESC,
                        pw.SurgeryProcedureGuid ASC
                ) AS RankWithinIncision,
                MAX(CASE WHEN pw.NoBill = 1 THEN 0.00 ELSE ISNULL(pw.ManualValue, 0.00) END) OVER (
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
                        ih.NoBill ASC,
                        CASE WHEN ih.ResolvedManual = 'SOAT' THEN ISNULL(ih.SurgeryGroup, 0) ELSE 0 END DESC,
                        ISNULL(ih.ManualValue, 0.00) DESC,
                        ih.SurgeryProcedureGuid ASC
                ) AS SurgeonProcRank,
                ROW_NUMBER() OVER (
                    PARTITION BY ih.SurgeryGuid, ih.Anesthesiologist
                    ORDER BY
                        ih.NoBill ASC,
                        CASE WHEN ih.ResolvedManual = 'SOAT' THEN ISNULL(ih.SurgeryGroup, 0) ELSE 0 END DESC,
                        ISNULL(ih.ManualValue, 0.00) DESC,
                        ih.SurgeryProcedureGuid ASC
                ) AS AnesthProcRank,
                ROW_NUMBER() OVER (
                    PARTITION BY ih.SurgeryGuid, ih.SurgeonId2
                    ORDER BY
                        ih.NoBill ASC,
                        CASE WHEN ih.ResolvedManual = 'SOAT' THEN ISNULL(ih.SurgeryGroup, 0) ELSE 0 END DESC,
                        ISNULL(ih.ManualValue, 0.00) DESC,
                        ih.SurgeryProcedureGuid ASC
                ) AS Assist1ProcRank,
                ROW_NUMBER() OVER (
                    PARTITION BY ih.SurgeryGuid, ih.SurgeonId3
                    ORDER BY
                        ih.NoBill ASC,
                        CASE WHEN ih.ResolvedManual = 'SOAT' THEN ISNULL(ih.SurgeryGroup, 0) ELSE 0 END DESC,
                        ISNULL(ih.ManualValue, 0.00) DESC,
                        ih.SurgeryProcedureGuid ASC
                ) AS Assist2ProcRank
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
                    ORDER BY ce.Ranking DESC, ABS(ce.PriceModifier) DESC, ce.StartDate DESC, ce.ExceptionGuid ASC
                ) AS ExceptionPriorityRank
            FROM SpecialistHierarchy p
            LEFT JOIN [dbo].[ColombiaContractExceptions] ce
                ON ce.ContractGuid = p.ResolvedContractGuid
                AND ce.Active = 1
                AND CAST(p.DateTimePerformed AS DATE) >= ce.StartDate
                AND CAST(p.DateTimePerformed AS DATE) <= ISNULL(ce.EndDate, '9999-12-31')
                AND ce.Ranking IN (1, 2, 3, 4, 5, 6, 7, 8)
                AND (ce.Ranking <> 1 OR ce.ExceptionType = p.ArticleGroup)
                AND (ce.Ranking <> 2 OR ce.SurgeryGrp = p.SurgeryGroup)
                AND (ce.Ranking NOT IN (3, 4, 5, 6, 7, 8) OR ce.CupsCode = p.CUPSCode)
                AND (ce.ShiftType = 1 OR ce.ShiftType = p.RowShiftType)
                AND (ce.ServiceGroup = '00' OR ce.ServiceGroup = '04')
        ),
        ProceduresWithAppliedExceptions AS (
            SELECT a.*
            FROM AllMatchingExceptions a
            WHERE a.ExceptionPriorityRank = 1
        ),
        FinalLineItemPricing AS (
            SELECT
                pe.*,
                v.SubtypeCode,
                v.SubtypeName,
                CASE
                    WHEN v.SubtypeCode = 1 THEN pe.SurgeonProcRank
                    WHEN v.SubtypeCode = 2 THEN pe.AnesthProcRank
                    WHEN v.SubtypeCode = 3 THEN pe.Assist1ProcRank
                    WHEN v.SubtypeCode = 6 THEN pe.Assist2ProcRank
                    ELSE pe.SurgeonProcRank
                END AS SpecialistProcedureRank,
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
                  (1, N'Cirujano'),
                  (2, N'Anestesiologo'),
                  (3, N'Ayudante'),
                  (4, N'Sala'),
                  (5, N'Materiales'),
                  (6, N'Segundo Ayudante')
            ) v(SubtypeCode, SubtypeName)
        ),
        RemoveMissingStaff AS (
            SELECT rm.*
            FROM FinalLineItemPricing rm
            WHERE (rm.SubtypeCode = 1 AND rm.SurgeonId IS NOT NULL)
               OR (rm.SubtypeCode = 2 AND rm.Anesthesiologist IS NOT NULL)
               OR (rm.SubtypeCode = 3 AND rm.SurgeonId2 IS NOT NULL)
               OR (rm.SubtypeCode = 6 AND rm.SurgeonId3 IS NOT NULL)
               OR rm.SubtypeCode IN (4, 5)
        ),
        CatalogBaseUnits AS (
            SELECT
                f.*,
                CAST(
                    CASE
                        WHEN f.ResolvedManual = 'SOAT' AND f.SubtypeCode = 3 AND ISNULL(f.SurgeryGroup, 0) <= 5  THEN 0.00
                        WHEN f.ResolvedManual = 'SOAT' AND f.SubtypeCode = 6 AND ISNULL(f.SurgeryGroup, 0) <= 10 THEN 0.00
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
                        WHEN r.SubtypeCode IN (1, 2, 3, 6) THEN
                            CASE
                                WHEN r.SpecialistProcedureRank = 1 THEN
                                    CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END
                                WHEN r.SpecialistProcedureRank > 1 AND r.RankWithinIncision > 1 THEN
                                    CASE
                                        WHEN r.ResolvedManual = 'SOAT'    THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                        WHEN r.ResolvedManual LIKE 'ISS%' THEN 0.60 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                        ELSE 0.50
                                    END
                                WHEN r.SpecialistProcedureRank > 1 AND r.RankWithinIncision = 1 THEN
                                    CASE
                                        WHEN r.ResolvedManual = 'SOAT'    THEN 0.50 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                        WHEN r.ResolvedManual LIKE 'ISS%' THEN 0.75 * (CASE WHEN r.Laterality = 3 THEN 1.75 ELSE 1.00 END)
                                        ELSE 0.50
                                    END
                                ELSE 0.50
                            END
                        WHEN r.SubtypeCode IN (4, 5) THEN
                            CASE
                                WHEN r.IncisionSessionRank = 1 AND r.RankWithinIncision = 1 THEN
                                    CASE WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 ELSE 1.00 END
                                WHEN r.RankWithinIncision > 1 THEN 0.00
                                WHEN r.IncisionSessionRank > 1 AND r.RankWithinIncision = 1 THEN
                                    CASE
                                        WHEN r.ResolvedManual = 'SOAT'    THEN 0.75 * (CASE WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 ELSE 1.00 END)
                                        WHEN r.ResolvedManual LIKE 'ISS%' THEN 0.50 * (CASE WHEN r.Laterality = 3 AND r.SubtypeCode = 4 THEN 1.50 ELSE 1.00 END)
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
                    WHEN d.ResolvedManual = 'SOAT' AND d.DateTimePerformed < '2024-01-01'  THEN 'SMDLV'
                    WHEN d.ResolvedManual = 'SOAT' AND d.DateTimePerformed >= '2024-01-01' THEN 'UVB'
                    WHEN d.ResolvedManual LIKE 'ISS%'                                      THEN 'UVR'
                    ELSE 'COP'
                END AS ValueBasis,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM SurgicalDegradationRules d
            OUTER APPLY (
                SELECT TOP (1) up_inner.UnitValue
                FROM #UnitParameters up_inner
                WHERE up_inner.ContractType = CASE WHEN d.ManualValue IS NOT NULL AND d.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up_inner.UnitCategory = CASE
                      WHEN d.DateTimePerformed >= '2024-01-01' AND d.ResolvedManual = 'SOAT' THEN 'UVB'
                      WHEN d.DateTimePerformed < '2024-01-01'  AND d.ResolvedManual = 'SOAT' THEN 'SMDLV'
                      ELSE 'UVR'
                  END
                ORDER BY
                    CASE WHEN up_inner.CalendarYear = d.YearOfService THEN 0 ELSE 1 END ASC,
                    ABS(up_inner.CalendarYear - d.YearOfService) ASC,
                    up_inner.CalendarYear DESC
            ) up
        ),
        CalculatedLineItems AS (
            SELECT
                f.*,
                CASE
                    WHEN f.SubtypeCode = 1 THEN N'Surgeon'
                    WHEN f.SubtypeCode = 2 THEN N'Anesthesia'
                    WHEN f.SubtypeCode = 3 THEN N'Assistant1'
                    WHEN f.SubtypeCode = 6 THEN N'Assistant2'
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
                        WHEN f.ExceptionRanking IN (3, 5, 7, 8) THEN ISNULL(f.ExceptionPriceValue, 0.00) * f.ShiftMultiplier
                        ELSE (f.RawCatalogUnits * f.ShiftMultiplier * f.AppliedExceptionFactor * f.DegradationMultiplier * f.UnitMonetaryValue)
                    END AS DECIMAL(18,2)
                ) AS CalculatedLineTotal
            FROM FinalShiftAdjustments f
        )
        SELECT *
        INTO #SurgeryLineItems
        FROM CalculatedLineItems
        WHERE NOT (SubtypeCode IN (3, 4, 5, 6) AND CalculatedLineTotal = 0);

        -- ==========================================================================================
        -- 5.4c STATE INVALIDATION WORKFLOW (Multi-Procedure Safe Audit & Reset on Plan/Rate Change)
        -- ==========================================================================================
        DECLARE @SystemActionUser NVARCHAR(100) = N'System: Liquidation Engine';
        DECLARE @Reason NVARCHAR(500) = N'Forced recalculation due to Insurance Plan/Contract change.';

        INSERT INTO [dbo].[FeeManagementAudits] (
            AuditId, TransactionGuid, ActionTimestamp, ActionByUser, ActionType,
            OldWorkflowStatus, NewWorkflowStatus,
            OldAmount, NewAmount, ReasonCode, InternalNotes
        )
        SELECT
            CAST(NEWID() AS NVARCHAR(50)),
            pt.TransactionGuid,
            @Now,
            @SystemActionUser,
            N'System Recalculation',
            pt.CurrentWorkflowStatus,
            N'Pending Re-Approval',
            pt.NetAmount,
            ROUND(f.CalculatedLineTotal, -2),
            N'PLAN_CHANGE',
            @Reason
        FROM [dbo].[PatientTransactions] pt WITH (UPDLOCK, ROWLOCK)
        INNER JOIN #SurgeryLineItems f
            ON f.SurgeryGuid = pt.SurgeryGuid
            AND f.SubtypeCode IN (1, 2, 3, 6)
            AND f.ResolvedProfessionalId = pt.ChargePhysician
            AND (pt.ChargeCode IS NULL OR pt.ChargeCode = f.ResolvedProfessionalType)
            AND (
                pt.ItemMasterGuid = f.ProcedureGuid
                OR (pt.ItemMasterGuid IS NULL AND pt.CupsCode = f.CUPSCode)
            )
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Facility = @FacilityId
          AND pt.TransactionType = N'Honorary'
          AND pt.[Status] = N'Active'
          AND pt.DIANInvoiceBatchId IS NULL
          AND pt.RIPSBatchId IS NULL
          AND ISNULL(pt.CurrentWorkflowStatus, N'Pending Review') <> N'Pending Review'
          AND (
              ISNULL(pt.ClaimGuid, N'') <> ISNULL(f.ResolvedClaimGuid, N'')
              OR ISNULL(pt.NetAmount, -1.00) <> ROUND(f.CalculatedLineTotal, -2)
          );

        UPDATE pt
        SET
            pt.NetAmount = calc.RoundedNet,
            pt.TaxAmount = calc.RoundedTax,
            pt.TaxRate = calc.AppliedTaxRate,
            pt.PerItemChargeAmount = calc.RoundedNet + calc.RoundedTax,
            pt.TotalChargeAmount = f.CalculatedLineTotal,
            pt.OriginalCalculatedAmount = calc.RoundedNet,
            pt.CurrentWorkflowStatus = N'Pending Re-Approval',
            pt.ApprovedForBilling = 0,
            pt.ClaimGuid = f.ResolvedClaimGuid,
            pt.ContractGuid = f.ResolvedContractGuid,
            pt.RevenueCode = f.ResolvedManual,
            pt.DateTimeLastUpdated = @Now,
            pt.LastUpdatedBy = N'System: Plan Change'
        FROM [dbo].[PatientTransactions] pt
        INNER JOIN #SurgeryLineItems f
            ON f.SurgeryGuid = pt.SurgeryGuid
            AND f.SubtypeCode IN (1, 2, 3, 6)
            AND f.ResolvedProfessionalId = pt.ChargePhysician
            AND (pt.ChargeCode IS NULL OR pt.ChargeCode = f.ResolvedProfessionalType)
            AND (
                pt.ItemMasterGuid = f.ProcedureGuid
                OR (pt.ItemMasterGuid IS NULL AND pt.CupsCode = f.CUPSCode)
            )
        CROSS APPLY (
            SELECT
                CASE
                    WHEN f.DiagnosisCode LIKE N'%Z41.1%' OR f.DiagnosisCode LIKE N'%Z41.8%' OR f.DiagnosisCode LIKE N'%Z41.9%'
                      OR f.DiagnosisCode LIKE N'%Z411%'  OR f.DiagnosisCode LIKE N'%Z418%'  OR f.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate
        ) tx
        CROSS APPLY (
            SELECT
                ROUND(f.CalculatedLineTotal, -2) AS RoundedNet,
                CASE WHEN tx.AppliedTaxRate > 0 THEN ROUND(f.CalculatedLineTotal * tx.AppliedTaxRate, -2) ELSE 0.00 END AS RoundedTax,
                tx.AppliedTaxRate
        ) calc
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Facility = @FacilityId
          AND pt.TransactionType = N'Honorary'
          AND pt.[Status] = N'Active'
          AND pt.DIANInvoiceBatchId IS NULL
          AND pt.RIPSBatchId IS NULL
          AND ISNULL(pt.CurrentWorkflowStatus, N'Pending Review') <> N'Pending Review'
          AND (
              ISNULL(pt.ClaimGuid, N'') <> ISNULL(f.ResolvedClaimGuid, N'')
              OR ISNULL(pt.NetAmount, -1.00) <> calc.RoundedNet
          );

        -- Track A: Individual Surgical Sub-Lines
        INSERT INTO [dbo].[PatientTransactions] (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid,
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach,
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime,
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount,
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount,
            PerItemChargeAmount, [Status], ChargeCode, ChargePhysician, TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount,
            CurrentWorkflowStatus, OriginalCalculatedAmount, ApprovedForBilling
        )
        SELECT
            @FacilityId,
            @PatientId,
            @PatientVisit,
            calc.MappedTxType,
            f.SurgeryGuid,
            f.ResolvedClaimGuid,
            f.SurgeryGuid,
            f.ResolvedContractGuid,
            f.ExceptionGuid,
            '04',
            f.UnitMonetaryValue,
            f.SubtypeName,
            f.SurgeryGroup,
            f.SurgeryApproach,
            CASE WHEN f.RankWithinIncision > 1 THEN 1 ELSE 0 END,
            f.RowShiftType,
            0.00,
            f.CUPSCode,
            NULL,
            f.DateTimePerformed,
            @Now,
            f.ResolvedManual,
            1,
            f.SpecialistProcedureRank,
            f.DiagnosisCode,
            f.RawCatalogUnits,
            f.AppliedExceptionFactor,
            f.DegradationMultiplier,
            f.ShiftMultiplier,
            f.ValueBasis,
            calc.RoundedNet,
            calc.RoundedTax,
            0.00,
            calc.RoundedNet + calc.RoundedTax,
            CASE WHEN f.NoBill = 1 THEN N'Unbillable' ELSE N'Active' END,
            f.ResolvedProfessionalType,
            f.ResolvedProfessionalId,
            NEWID(),
            N'Unidad',
            NULL,
            f.ProcedureGuid,
            f.ProcedureDescription,
            ISNULL(f.ItemNumber, f.CUPSCode),
            f.Type,
            f.Category,
            f.EnteredBy,
            f.DateTimePerformed,
            calc.AppliedTaxRate,
            0,
            f.ProcedureDescription,
            f.CalculatedLineTotal,
            N'Pending Review',
            calc.RoundedNet,
            CASE WHEN f.SubtypeCode IN (1, 2, 3, 6) THEN 0 ELSE 1 END
        FROM #SurgeryLineItems f
        CROSS APPLY (
            SELECT
                CASE
                    WHEN f.SubtypeCode IN (1, 2, 3, 6) THEN N'Honorary'
                    WHEN f.SubtypeCode = 4 THEN N'RoomRights'
                    WHEN f.SubtypeCode = 5 THEN N'Materials'
                    ELSE N'Surgery'
                END AS MappedTxType,
                CASE
                    WHEN f.DiagnosisCode LIKE N'%Z41.1%' OR f.DiagnosisCode LIKE N'%Z41.8%' OR f.DiagnosisCode LIKE N'%Z41.9%'
                      OR f.DiagnosisCode LIKE N'%Z411%'  OR f.DiagnosisCode LIKE N'%Z418%'  OR f.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate
        ) tx
        CROSS APPLY (
            SELECT
                tx.MappedTxType,
                ROUND(f.CalculatedLineTotal, -2) AS RoundedNet,
                CASE WHEN tx.AppliedTaxRate > 0 THEN ROUND(f.CalculatedLineTotal * tx.AppliedTaxRate, -2) ELSE 0.00 END AS RoundedTax,
                tx.AppliedTaxRate
        ) calc
        WHERE NOT EXISTS (
            SELECT 1
            FROM [dbo].[PatientTransactions] pt
            WHERE pt.SurgeryGuid = f.SurgeryGuid
              AND pt.Facility = @FacilityId
              AND pt.[Status] = N'Active'
              AND pt.TransactionType = calc.MappedTxType
              AND (
                  (
                      calc.MappedTxType = N'Honorary'
                      AND pt.ChargePhysician = f.ResolvedProfessionalId
                      AND (pt.ChargeCode IS NULL OR pt.ChargeCode = f.ResolvedProfessionalType)
                      AND (pt.ItemMasterGuid = f.ProcedureGuid OR (pt.ItemMasterGuid IS NULL AND pt.CupsCode = f.CUPSCode))
                  )
                  OR (
                      calc.MappedTxType <> N'Honorary'
                      AND (pt.DIANInvoiceBatchId IS NOT NULL OR pt.RIPSBatchId IS NOT NULL)
                      AND (pt.ItemMasterGuid = f.ProcedureGuid OR pt.CupsCode = f.CUPSCode)
                  )
              )
        );

        -- Track B: Bundle Master Header Line
        INSERT INTO [dbo].[PatientTransactions] (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid,
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach,
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime,
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount,
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount,
            PerItemChargeAmount, [Status], ChargeCode, ChargePhysician, TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount, CurrentWorkflowStatus
        )
        SELECT
            @FacilityId,
            @PatientId,
            @PatientVisit,
            N'BundleMaster',
            f.SurgeryGuid,
            f.ResolvedClaimGuid,
            f.SurgeryGuid,
            f.ResolvedContractGuid,
            NULL,
            '04',
            f.BundlePrice,
            N'Paquete Completo',
            NULL,
            MAX(f.SurgeryApproach),
            0,
            1,
            0.00,
            f.BundleCupsCode,
            NULL,
            f.DateTimePerformed,
            @Now,
            f.ResolvedManual,
            1,
            0.00,
            f.DiagnosisCode,
            NULL,
            f.BundlePrice,
            1.00,
            1.00,
            'COP',
            calc.RoundedNet,
            calc.RoundedTax,
            0.00,
            calc.RoundedNet + calc.RoundedTax,
            N'Active',
            NULL,
            NULL,
            NEWID(),
            N'Unidad',
            NULL,
            MAX(f.ProcedureGuid),
            MAX(f.ProcedureDescription),
            ISNULL(MAX(f.ItemNumber), f.BundleCupsCode),
            NULL,
            NULL,
            MAX(f.EnteredBy),
            f.DateTimePerformed,
            calc.AppliedTaxRate,
            0,
            MAX(f.ProcedureDescription),
            f.BundlePrice,
            N'Pending Review'
        FROM #SurgeryLineItems f
        CROSS APPLY (
            SELECT
                CASE
                    WHEN f.DiagnosisCode LIKE N'%Z41.1%' OR f.DiagnosisCode LIKE N'%Z41.8%' OR f.DiagnosisCode LIKE N'%Z41.9%'
                      OR f.DiagnosisCode LIKE N'%Z411%'  OR f.DiagnosisCode LIKE N'%Z418%'  OR f.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate
        ) tx
        CROSS APPLY (
            SELECT
                ROUND(f.BundlePrice, -2) AS RoundedNet,
                CASE WHEN tx.AppliedTaxRate > 0 THEN ROUND(f.BundlePrice * tx.AppliedTaxRate, -2) ELSE 0.00 END AS RoundedTax,
                tx.AppliedTaxRate
        ) calc
        WHERE f.IsBundle = 1
          AND NOT EXISTS (
              SELECT 1
              FROM [dbo].[PatientTransactions] pt_locked
              WHERE pt_locked.SurgeryGuid = f.SurgeryGuid
                AND pt_locked.Facility = @FacilityId
                AND pt_locked.TransactionType = N'BundleMaster'
                AND pt_locked.[Status] = N'Active'
                AND (pt_locked.DIANInvoiceBatchId IS NOT NULL OR pt_locked.RIPSBatchId IS NOT NULL)
          )
        GROUP BY
            f.SurgeryGuid, f.BundleCupsCode, f.BundleDescription, f.BundlePrice,
            f.DateTimePerformed, f.ResolvedClaimGuid, f.ResolvedContractGuid,
            f.ResolvedManual, f.DiagnosisCode,
            calc.RoundedNet, calc.RoundedTax, calc.AppliedTaxRate;

        -- Track C: Additional Surgery Supplies (from SurgeryCharges)
        INSERT INTO [dbo].[PatientTransactions] (
            Facility, PatientId, PatientVisit, TransactionType, OrderGuid, ClaimGuid, SurgeryGuid, ContractGuid,
            ContractExceptionGuid, Ambito, BaseUnitValue, SurgicalComponent, SurgicalGroup, SurgicalApproach,
            SurgicalSequence, ShiftTypeApplied, SurchargeAmount, CupsCode, CUMCode, ExternalProcessedDateTime,
            DateTimeEntered, RevenueCode, TransactionQuantity, ItemCost, ItemSnomedCode, ItemAlternateCode, LocalAmount,
            USDBasePrice, USDPerItemChargeAmount, PaymentType, NetAmount, TaxAmount, DiscountAmount,
            PerItemChargeAmount, [Status], ChargeCode, ChargePhysician, TransactionGuid, UnitOfMeasure, TransactionNote, ItemMasterGuid, ItemName, ItemNumber,
            [ItemType], ItemCategory, EnteredBy, TransactionDateTime, TaxRate, DiscountRate, ItemDescription, TotalChargeAmount, CurrentWorkflowStatus
        )
        SELECT
            @FacilityId,
            @PatientId,
            @PatientVisit,
            N'Supplies',
            scx.SurgeryGuid,
            scx.ResolvedClaimGuid,
            scx.SurgeryGuid,
            scx.ResolvedContractGuid,
            NULL,
            '04',
            CAST(ISNULL(sc.BasePrice, 0.00) AS DECIMAL(18,2)),
            ISNULL(itm.ItemName, N'Material Especial / Osteosintesis'),
            NULL,
            NULL,
            0,
            2,
            0.00,
            itm.ItemNumber,
            itm.ItemNumber,
            ISNULL(scx.DateTimePerformed, sc.DateTimeEntered),
            @Now,
            scx.ResolvedManual,
            ISNULL(sc.Quantity, 1),
            0.00,
            scx.DiagnosisCode,
            sc.SurgeryUOM,
            ISNULL(itm.BasePrice, 0.00),
            1.00,
            1.00,
            'COP',
            calc.NetAmount,
            calc.TaxAmount,
            0.00,
            calc.NetAmount + calc.TaxAmount,
            CASE WHEN ISNULL(sp.NoBill, 0) = 1 THEN N'Unbillable' ELSE N'Active' END,
            NULL,
            NULL,
            NEWID(),
            N'Procedimiento',
            NULL,
            itm.ItemMasterGuid,
            itm.ItemName,
            itm.ItemNumber,
            itm.Type,
            itm.Category,
            sc.EnteredBy,
            sc.DateTimeEntered,
            calc.AppliedTaxRate,
            0,
            itm.ItemName,
            calc.NetAmount,
            N'Pending Review'
        FROM ClinicalGeniusEhr.dbo.SurgeryCharges sc
        INNER JOIN [dbo].[SurgeryProcedures] sp
            ON sp.SurgeryProcedureGuid = sc.SurgeryProcedureGuid
            AND sp.Active = 1
        INNER JOIN #SurgeryContext scx
            ON scx.SurgeryGuid = sp.SurgeryGuid
        INNER JOIN [dbo].[ItemMaster] itm
            ON sc.ItemMasterGuid = itm.ItemMasterGuid
        CROSS APPLY (
            SELECT
                CASE
                    WHEN ISNULL(sp.NoBill, 0) = 1 OR (scx.IsBundle = 1 AND scx.MaterialIncluded = 1) THEN 0.00
                    ELSE ISNULL(sc.NetAmount, 0.00)
                END AS EffectiveRawNet,
                CASE
                    WHEN scx.DiagnosisCode LIKE N'%Z41.1%' OR scx.DiagnosisCode LIKE N'%Z41.8%' OR scx.DiagnosisCode LIKE N'%Z41.9%'
                      OR scx.DiagnosisCode LIKE N'%Z411%'  OR scx.DiagnosisCode LIKE N'%Z418%'  OR scx.DiagnosisCode LIKE N'%Z419%'
                    THEN 0.19
                    ELSE 0.00
                END AS AppliedTaxRate
        ) base_sc
        CROSS APPLY (
            SELECT
                ROUND(base_sc.EffectiveRawNet, -2) AS NetAmount,
                CASE WHEN base_sc.AppliedTaxRate > 0 THEN ROUND(base_sc.EffectiveRawNet * base_sc.AppliedTaxRate, -2) ELSE 0.00 END AS TaxAmount,
                base_sc.AppliedTaxRate
        ) calc
        WHERE sc.Facility = @FacilityId
          AND sc.Active = 1
          AND NOT EXISTS (
              SELECT 1
              FROM [dbo].[PatientTransactions] pt_locked
              WHERE pt_locked.SurgeryGuid = scx.SurgeryGuid
                AND pt_locked.Facility = @FacilityId
                AND pt_locked.TransactionType = N'Supplies'
                AND pt_locked.ItemMasterGuid = itm.ItemMasterGuid
                AND pt_locked.[Status] = N'Active'
                AND (pt_locked.DIANInvoiceBatchId IS NOT NULL OR pt_locked.RIPSBatchId IS NOT NULL)
          );


        -- ##########################################################################################
        -- ##  STAGE 2: STATUTORY COPAY & COINSURANCE ENGINE
        -- ##########################################################################################

        IF @TargetClaimGuid <> N'Patient'
        BEGIN
            SELECT TOP (1)
                @PatientFinancialClass = ISNULL(NULLIF(LTRIM(RTRIM(pat.FinancialClass)), ''), 'A'),
                @CopayYearOfService = YEAR(pvt.AdmitDateTime)
            FROM ClinicalGeniusEhr.dbo.PatientVisits pvt
            LEFT JOIN ClinicalGeniusEhr.dbo.PatientTable pat
                ON (pat.RecordUniqueId = pvt.PatientId OR pat.PatientId = pvt.PatientId)
            WHERE pvt.PatientVisitUniqueId = @PatientVisit
              AND (pvt.FacilityId = @FacilityId OR pvt.FacilityId IS NULL)
            ORDER BY
                CASE WHEN pat.RecordUniqueId = pvt.PatientId THEN 0 ELSE 1 END ASC,
                CASE WHEN pvt.FacilityId = @FacilityId THEN 0 ELSE 1 END ASC;

            SET @CopayYearOfService = ISNULL(@CopayYearOfService, YEAR(@Now));

            SELECT TOP (1)
                @MaxAllowedCopayPerEvent = scl.MaxCapPerEvent
            FROM #StatutoryCopayLimits scl
            WHERE scl.FinancialClass = @PatientFinancialClass
            ORDER BY
                CASE WHEN scl.CalendarYear = @CopayYearOfService THEN 0 ELSE 1 END ASC,
                ABS(scl.CalendarYear - @CopayYearOfService) ASC,
                scl.CalendarYear DESC;

            SET @MaxAllowedCopayPerEvent = ISNULL(@MaxAllowedCopayPerEvent, 99999999.99);
            IF @PatientFinancialClass = 'S1'
                SET @MaxAllowedCopayPerEvent = 0.00;

            -- 2.1 Base Aggregation (null-safe and clamped at >= 0)
            UPDATE pyc
            SET
                pyc.Copay = calc_pyc.EffectiveCopay,
                pyc.MedicalCoinsurance = calc_pyc.CalculatedCoinsurance,
                pyc.PayerCoverageAmount = CASE
                    WHEN (ClaimTotals.TotalNet - calc_pyc.EffectiveCopay - calc_pyc.CalculatedCoinsurance) > 0.00
                    THEN ROUND(ClaimTotals.TotalNet - calc_pyc.EffectiveCopay - calc_pyc.CalculatedCoinsurance, -2)
                    ELSE 0.00
                END,
                pyc.LastUpdatedBy = N'CopayEngine_InitialAgg'
            FROM [dbo].[PayerClaims] pyc WITH (UPDLOCK, ROWLOCK)
            CROSS APPLY (
                SELECT ISNULL(SUM(pt.NetAmount), 0.00) AS TotalNet
                FROM [dbo].[PatientTransactions] pt
                WHERE pt.ClaimGuid = @TargetClaimGuid
                  AND pt.[Status] = N'Active'
                  AND pt.Facility = @FacilityId
            ) ClaimTotals
            CROSS APPLY (
                SELECT
                    ROUND(
                        CASE
                            WHEN ISNULL(pyc.Copay, 0.00) > ClaimTotals.TotalNet THEN ClaimTotals.TotalNet
                            WHEN ISNULL(pyc.Copay, 0.00) < 0.00 THEN 0.00
                            ELSE ISNULL(pyc.Copay, 0.00)
                        END,
                        -2
                    ) AS EffectiveCopay,
                    ROUND(ClaimTotals.TotalNet * (ISNULL(pyc.CoInsurance, 0.00) / 100.00), -2) AS CalculatedCoinsurance
            ) calc_pyc
            WHERE pyc.ClaimGuid = @TargetClaimGuid
              AND pyc.Facility = @FacilityId;

            -- 2.2 Event Evaluation across prior visit claims
            SELECT
                @PriorVisitLiability = ISNULL(SUM(ISNULL(Copay, 0.00) + ISNULL(MedicalCoinsurance, 0.00)), 0.00)
            FROM [dbo].[PayerClaims]
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND ClaimGuid <> @TargetClaimGuid;

            SELECT
                @CurrentClaimLiability = ISNULL(Copay, 0.00) + ISNULL(MedicalCoinsurance, 0.00)
            FROM [dbo].[PayerClaims]
            WHERE ClaimGuid = @TargetClaimGuid
              AND Facility = @FacilityId;

            -- 2.3 Statutory Event Cap Enforcement
            IF (@PriorVisitLiability + @CurrentClaimLiability) > @MaxAllowedCopayPerEvent
            BEGIN
                SET @AvailableCapSpace = @MaxAllowedCopayPerEvent - @PriorVisitLiability;
                IF @AvailableCapSpace < 0.00
                    SET @AvailableCapSpace = 0.00;

                UPDATE pyc
                SET
                    pyc.Copay = capped.CappedCopay,
                    pyc.MedicalCoinsurance = capped.CappedCoinsurance,
                    pyc.PayerCoverageAmount = ROUND(
                        ISNULL(pyc.PayerCoverageAmount, 0.00) + (@CurrentClaimLiability - (capped.CappedCopay + capped.CappedCoinsurance)),
                        -2
                    ),
                    pyc.LastUpdatedBy = N'CopayEngine_EventCapped'
                FROM [dbo].[PayerClaims] pyc WITH (UPDLOCK, ROWLOCK)
                CROSS APPLY (
                    SELECT
                        ROUND(
                            CASE
                                WHEN ISNULL(pyc.Copay, 0.00) > @AvailableCapSpace THEN @AvailableCapSpace
                                ELSE ISNULL(pyc.Copay, 0.00)
                            END,
                            -2
                        ) AS CappedCopay,
                        ROUND(
                            CASE
                                WHEN ISNULL(pyc.Copay, 0.00) >= @AvailableCapSpace THEN 0.00
                                ELSE (@AvailableCapSpace - ISNULL(pyc.Copay, 0.00))
                            END,
                            -2
                        ) AS CappedCoinsurance
                ) capped
                WHERE pyc.ClaimGuid = @TargetClaimGuid
                  AND pyc.Facility = @FacilityId;
            END
        END

        IF @TranCount = 0
            COMMIT TRANSACTION;


        -- ##########################################################################################
        -- ##  STAGE 3: CUPS INVOICE SCRUBBER (Read-Only Defect Queue)
        -- ##########################################################################################

        SELECT TOP (1)
            @NormalizedSex = CASE
                WHEN LTRIM(RTRIM(pat.PatientSex)) LIKE 'M%' THEN 'M'
                WHEN LTRIM(RTRIM(pat.PatientSex)) LIKE 'F%' THEN 'F'
                ELSE 'I'
            END,
            @AgeInYears = DATEDIFF(YEAR, pat.PatientDOB, @Now) -
                          CASE
                              WHEN DATEADD(YEAR, DATEDIFF(YEAR, pat.PatientDOB, @Now), pat.PatientDOB) > @Now THEN 1
                              ELSE 0
                          END
        FROM ClinicalGeniusEhr.dbo.PatientTable pat
        WHERE pat.RecordUniqueId = @PatientId OR pat.PatientId = @PatientId
        ORDER BY CASE WHEN pat.RecordUniqueId = @PatientId THEN 0 ELSE 1 END ASC;

        ;WITH VisitAggregates AS (
            SELECT
                a.CupsCode,
                SUM(a.LineQty) AS TotalVisitQuantity
            FROM (
                SELECT
                    pt.CupsCode,
                    ISNULL(pt.OrderGuid, pt.TransactionGuid) AS DistinctOrderRef,
                    MAX(pt.TransactionQuantity) AS LineQty
                FROM [dbo].[PatientTransactions] pt
                WHERE pt.PatientVisit = @PatientVisit
                  AND pt.Facility = @FacilityId
                  AND pt.[Status] = N'Active'
                  AND (
                      (@TargetClaimGuid = N'Patient' AND (pt.ClaimGuid IS NULL OR pt.ClaimGuid = N'Patient'))
                      OR (@TargetClaimGuid <> N'Patient' AND pt.ClaimGuid = @TargetClaimGuid)
                  )
                GROUP BY pt.CupsCode, ISNULL(pt.OrderGuid, pt.TransactionGuid)
            ) a
            GROUP BY a.CupsCode
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

                -- Error 1: Gender Mismatch (supports 'M'/'Male'/'Masculino' and 'F'/'Female'/'Femenino')
                CASE
                    WHEN LTRIM(RTRIM(c.Sexo)) = 'F' AND @NormalizedSex = 'M'
                    THEN N'Incoherencia de género: procedimiento exclusivo para mujeres facturado a un paciente varón.'
                    WHEN LTRIM(RTRIM(c.Sexo)) = 'M' AND @NormalizedSex = 'F'
                    THEN N'Incongruencia de género: procedimiento exclusivo para hombres facturado a una paciente mujer.'
                    ELSE NULL
                END AS GenderError,

                -- Error 2: Quantity Limit Exceeded
                CASE
                    WHEN TRY_CAST(c.Cant_max AS INT) > 0 AND va.TotalVisitQuantity > TRY_CAST(c.Cant_max AS INT)
                    THEN CONCAT(N'Cantidad excedida: Facturado ', va.TotalVisitQuantity, N'. El máximo permitido por visita es ', c.Cant_max, N'.')
                    ELSE NULL
                END AS QuantityError,

                -- Error 3: Missing Required Diagnosis (catches NULL, blank, and 'none' placeholder)
                CASE
                    WHEN LTRIM(RTRIM(c.Dx_requerido)) = '1'
                         AND (
                             NULLIF(LTRIM(RTRIM(pt.ItemSnomedCode)), N'') IS NULL
                             OR LOWER(LTRIM(RTRIM(pt.ItemSnomedCode))) IN (N'none', N'n/a', N'null')
                         )
                    THEN N'Diagnóstico requerido: este procedimiento no se puede facturar sin un código ICD-10 asociado.'
                    ELSE NULL
                END AS DiagnosisError,

                ROW_NUMBER() OVER (
                    PARTITION BY pt.OrderGuid, pt.CupsCode
                    ORDER BY
                        CASE WHEN pt.TransactionType IN (N'Surgery', N'Procedure', N'BundleMaster', N'Honorary') THEN 1 ELSE 2 END ASC,
                        pt.DateTimeEntered DESC,
                        pt.TransactionGuid ASC
                ) AS DedupRank
            FROM [dbo].[PatientTransactions] pt
            INNER JOIN VisitAggregates va
                ON pt.CupsCode = va.CupsCode
            INNER JOIN [dbo].[COLCups] c
                ON pt.CupsCode = c.CUPSCode
            WHERE pt.PatientVisit = @PatientVisit
              AND pt.Facility = @FacilityId
              AND pt.[Status] = N'Active'
              AND (
                  (@TargetClaimGuid = N'Patient' AND (pt.ClaimGuid IS NULL OR pt.ClaimGuid = N'Patient'))
                  OR (@TargetClaimGuid <> N'Patient' AND pt.ClaimGuid = @TargetClaimGuid)
              )
        )
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
                    ISNULL(N' | ' + GenderError, N'') +
                    ISNULL(N' | ' + QuantityError, N'') +
                    ISNULL(N' | ' + DiagnosisError, N''),
                1, 3, N''), N'') AS ScrubberViolationMessage
            FROM ScrubberEvaluations
        ) FinalDefects
        WHERE ScrubberViolationMessage <> N''
          AND DedupRank = 1
        ORDER BY DateTimeEntered ASC, OrderGuid ASC;

    END TRY
    BEGIN CATCH
        IF @TranCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @TranCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_COLLiquidateClaim;

        IF OBJECT_ID('tempdb..#ColombianHolidays')    IS NOT NULL DROP TABLE #ColombianHolidays;
        IF OBJECT_ID('tempdb..#UnitParameters')       IS NOT NULL DROP TABLE #UnitParameters;
        IF OBJECT_ID('tempdb..#StatutoryCopayLimits') IS NOT NULL DROP TABLE #StatutoryCopayLimits;
        IF OBJECT_ID('tempdb..#SurgeryContext')       IS NOT NULL DROP TABLE #SurgeryContext;
        IF OBJECT_ID('tempdb..#SurgeryLineItems')     IS NOT NULL DROP TABLE #SurgeryLineItems;

        THROW;
    END CATCH;

    IF OBJECT_ID('tempdb..#ColombianHolidays')    IS NOT NULL DROP TABLE #ColombianHolidays;
    IF OBJECT_ID('tempdb..#UnitParameters')       IS NOT NULL DROP TABLE #UnitParameters;
    IF OBJECT_ID('tempdb..#StatutoryCopayLimits') IS NOT NULL DROP TABLE #StatutoryCopayLimits;
    IF OBJECT_ID('tempdb..#SurgeryContext')       IS NOT NULL DROP TABLE #SurgeryContext;
    IF OBJECT_ID('tempdb..#SurgeryLineItems')     IS NOT NULL DROP TABLE #SurgeryLineItems;
END;
GO