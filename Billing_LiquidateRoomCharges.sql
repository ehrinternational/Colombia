USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLLiquidateRoomCharges ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE {odata}.{COLLiquidateRoomCharges}
    @PatientVisit    NVARCHAR(50),
    @FacilityId      NVARCHAR(50),
    @TargetClaimGuid NVARCHAR(50) 
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ==========================================================================================
    -- 1. Targeted Context Resolution & Patient Binding
    -- ==========================================================================================
    DECLARE @ClaimGuid        NVARCHAR(50),
            @ContractGuid     NVARCHAR(50),
            @Manual           VARCHAR(20),
            @AdjustmentPct    DECIMAL(5,2),
            @PatientId        NVARCHAR(50),
            @VisitDiagnosis   NVARCHAR(50);

    SELECT TOP 1 @PatientId = PatientId
    FROM ClinicalGeniusEhr.dbo.PatientVisits WITH(NOLOCK)
    WHERE PatientVisitUniqueId = @PatientVisit AND FacilityId = @FacilityId;

    -- Fetch the most recent active diagnosis code for the visit from PatientProblems
    SELECT TOP 1 @VisitDiagnosis = prb.ProblemCode 
    FROM ClinicalGeniusEhr.dbo.PatientProblems prb WITH(NOLOCK) 
    WHERE prb.PatientVisit = @PatientVisit 
      AND prb.Status = 'Active' 
    ORDER BY prb.DateTimeEntered DESC;

    SET @VisitDiagnosis = ISNULL(@VisitDiagnosis, 'none');

    -- Route A: Patient Responsibility
    IF @TargetClaimGuid = 'Patient'
    BEGIN
        SET @ClaimGuid     = NULL;
        SET @ContractGuid  = NULL;
        SET @Manual        = 'SOAT';
        SET @AdjustmentPct = 0.00;
    END
    -- Route B: Explicit Payer Claim Targeted
    ELSE 
    BEGIN
        SELECT TOP 1 
            @ClaimGuid     = pyc.ClaimGuid,
            @ContractGuid  = isc.ContractGuid,
            @Manual        = ISNULL(isc.EntityCode, 'SOAT'),
            @AdjustmentPct = ISNULL(isc.AdjustmentPct, 0.00)
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

    -- Pre-load Unit Parameters globally into tempdb
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
        -- 2. Auto-Assign Unassigned Bed Assignments to Target Claim (When running for an insurance claim)
        -- ==========================================================================================
        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.PatientBedAssignments WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND FacilityId = @FacilityId
              AND ClaimGuid IS NULL;
        END

        -- ==========================================================================================
        -- 3. Targeted Staging Clear (Safeguards Invoiced Records)
        -- ==========================================================================================
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Stays'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Stay'
          AND Status NOT IN ('Invoiced', 'Billed', 'Canceled') 
          AND (
              (@TargetClaimGuid = 'Patient' AND ClaimGuid IS NULL) OR
              (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

        -- ==========================================================================================
        -- 4. Execution Pipeline Matrix
        -- ==========================================================================================
        ;WITH Tally(n) AS (
            SELECT TOP 1000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
            FROM sys.all_columns a
            CROSS JOIN (SELECT TOP 2 * FROM sys.all_columns) b
        ),
        ExpandedStayDays AS (
            SELECT 
                ba.BedAssignmentGuid AS StayGuid,
                ba.PatientVisit,
                r.CaseType AS BedCategoryCode,   
                @FacilityId AS FacilityId,
                @VisitDiagnosis AS DiagnosisCode,
                CAST(DATEADD(DAY, t.n, ba.DateTimeAssigned) AS DATE) AS StayCalendarDate,
                YEAR(DATEADD(DAY, t.n, ba.DateTimeAssigned)) AS YearOfService,
                ba.DateTimeAssigned,
                ba.DateTimeCheckedOut
            FROM ClinicalGeniusEhr.dbo.PatientBedAssignments ba WITH(NOLOCK)
            INNER JOIN ClinicalGeniusEhr.dbo.FacilityPatientRoomsAndBeds r WITH(NOLOCK)
                ON r.RoomGuid = ba.RoomGuid
            INNER JOIN Tally t ON t.n <= DATEDIFF(DAY, ba.DateTimeAssigned, ISNULL(ba.DateTimeCheckedOut, GETDATE()))
            WHERE ba.PatientVisit = @PatientVisit
              AND ba.FacilityId = @FacilityId
              AND r.CaseType IS NOT NULL 
              AND r.CaseType <> '' 
              AND r.CaseType <> ' '
              AND (
                  (@TargetClaimGuid = 'Patient' AND ba.ClaimGuid IS NULL) OR
                  (@TargetClaimGuid <> 'Patient' AND ba.ClaimGuid = @TargetClaimGuid)
              )
        ),
        DeduplicatedStayDays AS (
            SELECT 
                StayGuid,
                PatientVisit,
                BedCategoryCode,
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
                    WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN @Manual = 'ISS_2001'             THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                    ELSE 0.00 
                END AS RoomCatalogUnits,
                CASE 
                    WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
                    WHEN @Manual = 'ISS_2001'             THEN mvx.ISS2001Article
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
                              AND es.StayCalendarDate >= CAST(s.DateTimePerformed AS DATE)
                              AND es.StayCalendarDate <= CAST(DATEADD(DAY, 1, s.DateTimePerformed) AS DATE)
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
                    WHEN @Manual = 'SOAT' AND ex.StayCalendarDate < '2024-01-01'  THEN 'SMDLV'
                    WHEN @Manual = 'SOAT' AND ex.StayCalendarDate >= '2024-01-01' THEN 'UVB'
                    WHEN @Manual LIKE 'ISS%'                              THEN 'UVR' 
                    ELSE 'COP' 
                END AS ValueBasis,
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM AllMatchingStayExceptions ex
            OUTER APPLY (
                SELECT TOP 1 UnitValue 
                FROM #UnitParameters up 
                WHERE up.ContractType = CASE WHEN @Manual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up.CalendarYear = ex.YearOfService
                  AND up.UnitCategory = CASE WHEN ex.StayCalendarDate >= '2024-01-01' AND @Manual = 'SOAT' THEN 'UVB'
                                             WHEN ex.StayCalendarDate < '2024-01-01'  AND @Manual = 'SOAT' THEN 'SMDLV'
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
                        WHEN @Manual LIKE 'ISS%' THEN (c.RoomCatalogUnits * c.BaseCalculatedValue)
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
            ROUND(f.DayLineNetAmount, -2) AS NetAmount,    
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.DayLineNetAmount * 0.19, -2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.DayLineNetAmount + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.DayLineNetAmount * 0.19, -2) 
                    ELSE 0.00 
                END, -2) AS PerItemChargeAmount, 
            'Active' AS [Status]
        FROM FinalStayLiquidationLines f;

        COMMIT TRANSACTION;
        SELECT 'HOSPITAL STAYS LIQUIDATED SUCCESSFULLY' AS ExecutionStatus;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrSeverity INT       = ERROR_SEVERITY(),
                @ErrState INT          = ERROR_STATE();

        RAISERROR (@ErrMsg, @ErrSeverity, @ErrState);
    END CATCH;

    IF OBJECT_ID('tempdb..#UnitParameters') IS NOT NULL DROP TABLE #UnitParameters;
END;
GO