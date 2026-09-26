USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  LiquidateProcedures ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE {odata}.{LiquidateProcedures}
    @PatientVisit   NVARCHAR(50),
    @FacilityId     NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ==========================================================================================
    -- 1. Self-Resolving Context Resolution  ++Vlidated DS
    -- ==========================================================================================
    DECLARE @DefaultClaimGuid NVARCHAR(50),
        @DefaultContractGuid NVARCHAR(50),
        @DefaultManual       VARCHAR(20) = 'SOAT',
        @DefaultAdjustmentPct DECIMAL(5,2) = 0.00,
        @PatientId           NVARCHAR(50);

    SELECT TOP 1 @PatientId = PatientId
    FROM ClinicalGeniusEhr.dbo.PatientVisits WITH(NOLOCK)
    WHERE PatientVisitUniqueId = @PatientVisit AND FacilityId = @FacilityId;

    SELECT TOP 1 
        @DefaultClaimGuid    = pyc.ClaimGuid,
        @DefaultContractGuid = isc.ContractGuid,
        @DefaultManual       = ISNULL(isc.EntityCode, 'SOAT'),
        @DefaultAdjustmentPct = ISNULL(isc.AdjustmentPct, 0.00)
    FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
    INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
        ON ppy.PatientPayerGuid = pyc.PayerGuid
    INNER JOIN ClinicalGeniusSupplyChain.dbo.InsurancePlans isp WITH(NOLOCK) 
        ON isp.PlanGuid = ppy.PayerPlan
    INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
        ON isc.ContractGuid = isp.ContractGuid
    WHERE pyc.PatientVisit = @PatientVisit
      AND pyc.FacilityId = @FacilityId
      AND pyc.Status = 'Pending'
    ORDER BY pyc.BatchNumber ASC;

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
        ('2026-12-08'),('2026-12-25');
    
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
        -- 2. Targeted Staging Clear (Standalone Procedures ONLY)
        -- ==========================================================================================

        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Procedures'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Procedure'
          AND SurgeryGuid IS NULL
          AND Status <> 'Canceled';

        -- ==========================================================================================
        -- 3. Execution Pipeline Matrix
        -- ==========================================================================================

        ;WITH ProcedureList AS (
            SELECT 
                pp.ProcedureGuid, 
                pp.ProcedureCode, 
                pp.ProcedureDescription, 
                pp.LaterialityCode, 
                pp.ServiceGroup,
                
                -- Capture procedure-level claim or fallback to default
                ISNULL(pp.ClaimGuid, @DefaultClaimGuid) AS ResolvedClaimGuid,
                ISNULL(cinfo.ContractGuid, @DefaultContractGuid) AS ResolvedContractGuid,
                ISNULL(cinfo.EntityCode, @DefaultManual) AS ResolvedManual,
                ISNULL(cinfo.AdjustmentPct, @DefaultAdjustmentPct) AS ResolvedAdjustmentPct,

                ISNULL(pp.NoBill, 0) AS IsUnbillable,
                ISNULL(amx.Ambity, '01') AS Ambity, 
                
                -- Dynamic Catalog Value resolution routing through resolved manual
                CASE 
                    WHEN ISNULL(cinfo.EntityCode, @DefaultManual) = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS DECIMAL(18,4))
                    WHEN ISNULL(cinfo.EntityCode, @DefaultManual) = 'ISS_2001' THEN ISNULL(mvx.ISS2001Value, CAST(mvx.ISS2001UVR AS DECIMAL(18,2)))
                    ELSE 0.00 
                END AS CatalogValue,

                -- Surgery Group mapping
                CASE 
                    WHEN ISNULL(cinfo.EntityCode, @DefaultManual) = 'SOAT' THEN TRY_CAST(mvx.SOATValue AS INT) 
                    WHEN ISNULL(cinfo.EntityCode, @DefaultManual) = 'ISS_2001' THEN mvx.ISS2001UVR
                    ELSE NULL 
                END AS SurgeryGroup,

                -- Article mapping
                CASE 
                    WHEN ISNULL(cinfo.EntityCode, @DefaultManual) = 'SOAT' THEN mvx.SOATArticle 
                    WHEN ISNULL(cinfo.EntityCode, @DefaultManual) = 'ISS_2001' THEN mvx.ISS2001Article
                    ELSE NULL 
                END AS ArticleGroup,

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
            LEFT JOIN #ColombianHolidays h 
                ON h.HolidayDate = CAST(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS DATE)
            OUTER APPLY (
                SELECT TOP 1 
                    isc.ContractGuid,
                    isc.EntityCode,
                    ISNULL(isc.AdjustmentPct, 0.00) AS AdjustmentPct
                FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
                INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
                    ON ppy.PatientPayerGuid = pyc.PayerGuid
                INNER JOIN ClinicalGeniusSupplyChain.dbo.InsurancePlans isp WITH(NOLOCK) 
                    ON isp.PlanGuid = ppy.PayerPlan
                INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
                    ON isc.ContractGuid = isp.ContractGuid
                WHERE pyc.ClaimGuid = ISNULL(pp.ClaimGuid, @DefaultClaimGuid)
            ) cinfo
            OUTER APPLY (
                SELECT TOP 1 DPT.Ambity 
                FROM ClinicalGeniusSupplyChain.dbo.PatientDepartmentTracking PDT WITH(NOLOCK)
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
                WHERE mvl.CUPSCode = pp.ProcedureCode 
                  AND mvl.YearOfService = YEAR(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered))
                ORDER BY mvl.RecId DESC
            ) mvx
            WHERE pp.PatientVisit = @PatientVisit 
              AND pp.Active = 1
              AND pp.Facility = @FacilityId
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
            LEFT JOIN ClinicalGeniusSupplyChain.dbo.ContractExceptions ce WITH(NOLOCK) 
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
                ProcedureGuid, ProcedureCode, ProcedureDescription, LaterialityCode, ServiceGroup, 
                TargetDate, YearOfService, RowShiftType, ExceptionGuid, CatalogValue, Ambity,
                ResolvedClaimGuid, ResolvedContractGuid, ResolvedManual, ResolvedAdjustmentPct,
                IsUnbillable, ExceptionRanking,
                ISNULL(ExceptionPriceModifier, 0.00) AS PriceModifier,
                ISNULL(ExceptionPriceValue, 0.00) AS PriceValue
            FROM AllMatchingProcedureExceptions
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
                ISNULL(up.UnitValue, 1.00) AS UnitMonetaryValue
            FROM BaseUnits b
            OUTER APPLY (
                SELECT TOP 1 UnitValue 
                FROM #UnitParameters up 
                WHERE up.ContractType = CASE WHEN b.ResolvedManual LIKE 'ISS%' THEN 'ISS' ELSE 'SOAT' END
                  AND up.CalendarYear = b.YearOfService
                  AND up.UnitCategory = CASE WHEN b.TargetDate >= '2024-01-01' AND b.ResolvedManual = 'SOAT' THEN 'UVB'
                                             WHEN b.TargetDate < '2024-01-01' AND b.ResolvedManual = 'SOAT'  THEN 'SMDLV'
                                             ELSE 'UVR' END
            ) up
        ),
        CalculatedLines AS (
            SELECT 
                o.*,
                CAST(
                    CASE 
                        WHEN o.IsUnbillable = 1 THEN 0.00
                        WHEN o.ExceptionRanking IN (3, 5, 7, 8) THEN o.PriceValue * o.ShiftMultiplier
                        WHEN o.ResolvedManual = 'ISS_2001' AND o.RawCatalogUnits > 3000 THEN o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue
                        ELSE o.RawCatalogUnits * o.ShiftMultiplier * o.BaseCalculatedValue * o.UnitMonetaryValue 
                    END AS DECIMAL(18,2)
                ) AS LineTotal
            FROM FinalShiftAdjustments o
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
            f.ResolvedClaimGuid AS ClaimGuid,   
            NULL AS SurgeryGuid,                
            f.ResolvedContractGuid AS ContractGuid, 
            f.ExceptionGuid, 
            ISNULL(f.Ambity, '01') AS Ambity,    
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
            f.ResolvedManual AS RevenueCode,              
            1 AS Quantity,                       
            1 AS ItemCost,                       
            f.LaterialityCode AS ItemSnomedCode, 
            f.RawCatalogUnits AS ItemAlternateCode, 
            f.BaseCalculatedValue AS LocalAmount, 
            1.00 AS USDBasePrice,                
            f.ShiftMultiplier AS USDPerItemChargeAmount, 
            f.ValueBasis AS PaymentType, 
            f.LineTotal AS NetAmount,  
            0.00 AS TaxAmount, 
            0.00 AS DiscountAmount, 
            f.LineTotal AS PerItemChargeAmount, 
            CASE WHEN f.IsUnbillable = 1 THEN 'Unbillable' ELSE 'Active' END AS [Status]
        FROM CalculatedLines f;

        COMMIT TRANSACTION;
        SELECT 'Success' AS ExecutionStatus;

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