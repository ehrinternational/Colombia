USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLLiquidateProcedures ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE {odata}.{COLLiquidateProcedures}
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
    DECLARE @ResolvedClaimGuid    NVARCHAR(50),
            @ResolvedContractGuid  NVARCHAR(50),
            @ResolvedManual        VARCHAR(20),
            @ResolvedAdjustmentPct DECIMAL(5,2),
            @ResolvedNightCharges  Bit,
            @PatientId             NVARCHAR(50);

    SELECT TOP 1 @PatientId = PatientId
    FROM ClinicalGeniusEhr.dbo.PatientVisits WITH(NOLOCK)
    WHERE PatientVisitUniqueId = @PatientVisit AND FacilityId = @FacilityId;

    -- Route A: Patient Responsibility (Out-of-pocket / Unassigned items only)
    IF @TargetClaimGuid = 'Patient'
    BEGIN
        SET @ResolvedClaimGuid     = NULL;
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
          AND pyc.FacilityId = @FacilityId;
    END

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
        ('SOAT', 2027, 'UVB', 12110.00),
        ('ISS',  2023, 'UVR', 1.00),
        ('ISS',  2024, 'UVR', 1.00),
        ('ISS',  2025, 'UVR', 1.00),
        ('ISS',  2026, 'UVR', 1.00),
        ('ISS',  2027, 'UVR', 1.00);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ==========================================================================================
        -- 2. Auto-Assign Unassigned Procedures to Target Claim (When running for an insurance claim)
        -- ==========================================================================================
        IF @TargetClaimGuid <> 'Patient'
        BEGIN
            UPDATE ClinicalGeniusEhr.dbo.PatientProcedures WITH(ROWLOCK, UPDLOCK)
            SET ClaimGuid = @TargetClaimGuid
            WHERE PatientVisit = @PatientVisit
              AND Facility = @FacilityId
              AND ProcedureStatus = 'Active'
              AND ClaimGuid IS NULL;
        END

        -- ==========================================================================================
        -- 3. Targeted Staging Clear (Safeguards Invoiced Records & Prevents Cross-Claim Collisions)
        -- ==========================================================================================
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Procedures'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Procedure'
          AND SurgeryGuid IS NULL
          AND Status NOT IN ('Invoiced', 'Billed', 'Canceled') 
          AND (
              (@TargetClaimGuid = 'Patient' AND ClaimGuid IS NULL) OR
              (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
          );

        -- ==========================================================================================
        -- 4. Execution Pipeline Matrix
        -- ==========================================================================================
        ;WITH ProcedureList AS (
            SELECT 
                pp.ProcedureGuid, 
                pp.ProcedureCode, 
                pp.ProcedureDescription, 
                pp.LaterialityCode, 
                pp.ServiceGroup,
                
                @ResolvedClaimGuid AS ResolvedClaimGuid,
                @ResolvedContractGuid AS ResolvedContractGuid,
                @ResolvedManual AS ResolvedManual,
                @ResolvedAdjustmentPct AS ResolvedAdjustmentPct,
                @ResolvedNightCharges AS ResolvedNightCharges,
                ISNULL(pp.AssociatedDiagnosis, 'none') AS DiagnosisCode,

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
                    WHEN @ResolvedNightCharges = 0 OR ISNULL(amx.Ambity, '01') IN ('01', '02') OR ISNULL(pp.Priority, 'Routine') <> 'STAT' THEN 2
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
                              AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) >= DATEADD(HOUR, -24, s.DateTimePerformed)
                              AND ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) <= DATEADD(HOUR, 6, s.DateTimePerformed)
                        ) THEN 1 
                        ELSE 0 
                    END AS BIT
                ) AS IsProcedureAbsorbedByBundle
            FROM ClinicalGeniusEhr.dbo.PatientProcedures pp WITH(NOLOCK)
            LEFT JOIN #ColombianHolidays h 
                ON h.HolidayDate = CAST(ISNULL(pp.DateTimeOfProcedure, pp.DateTimeEntered) AS DATE)
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
                DiagnosisCode, IsProcedureAbsorbedByBundle,
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
            ROUND(f.LineTotal, -2) AS NetAmount,  
            CASE 
                WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.LineTotal * 0.19, -2) 
                ELSE 0.00 
            END AS TaxAmount, 
            0.00 AS DiscountAmount, 
            ROUND(f.LineTotal + 
                CASE 
                    WHEN f.DiagnosisCode LIKE '%Z41.1%' OR f.DiagnosisCode LIKE '%Z41.8%' OR f.DiagnosisCode LIKE '%Z41.9%' THEN ROUND(f.LineTotal * 0.19, -2) 
                    ELSE 0.00 
                END, -2) AS PerItemChargeAmount, 
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