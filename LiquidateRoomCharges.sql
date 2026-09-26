CREATE OR ALTER PROCEDURE ClinicalGeniusSupplyChain.dbo.LiquidateRoomCharges
    @PatientVisit   NVARCHAR(50),
    @FacilityId     NVARCHAR(50),
    @PatientId      NVARCHAR(50)  = NULL,
    @ContractGuid   NVARCHAR(50)  = NULL,
    @ClaimGuid      NVARCHAR(50)  = NULL,
    @Manual         VARCHAR(20)   = NULL,
    @AdjustmentPct  DECIMAL(5,2)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- ==========================================================================================
    -- 1. Self-Resolving Context Resolution (Enables standalone execution from UI)
    -- ==========================================================================================
    IF @ContractGuid IS NULL OR @ClaimGuid IS NULL OR @Manual IS NULL
    BEGIN
        SELECT TOP 1 
            @ClaimGuid     = pyc.ClaimGuid,
            @PatientId     = ISNULL(@PatientId, pyc.PatientId),
            @ContractGuid  = ppy.ContractGuid,
            @Manual        = isc.EntityCode,
            @AdjustmentPct = ISNULL(@AdjustmentPct, isc.AdjustmentPct)
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
            ON ppy.PatientPayerGuid = pyc.PayerGuid
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
            ON isc.ContractGuid = ppy.ContractGuid
        WHERE pyc.PatientVisit = @PatientVisit
          AND pyc.FacilityId = @FacilityId
          AND pyc.Status = 'Pending'
        ORDER BY pyc.BatchNumber ASC;

        -- Fallback baseline if uninsured or self-pay
        IF @ContractGuid IS NULL OR @Manual IS NULL
        BEGIN
            SET @Manual = 'SOAT';
            SET @AdjustmentPct = 0.00;
        END;
    END;

    -- Ensure PatientId is populated if not passed
    IF @PatientId IS NULL
    BEGIN
        SELECT TOP 1 @PatientId = PatientId
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims WITH(NOLOCK)
        WHERE PatientVisit = @PatientVisit AND FacilityId = @FacilityId;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ==========================================================================================
        -- 2. Targeted Staging Clear (Inpatient Hospital Stays ONLY)
        -- ==========================================================================================
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Stays'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Stay'
          AND Status <> 'Canceled'
          AND (ElectronicInvoiceStatus IS NULL OR ElectronicInvoiceStatus <> 'Transmitted');

        -- ==========================================================================================
        -- 3. Execution Pipeline Matrix
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
                    WHEN @Manual = 'ISS_2001'             THEN mvx.ISS2001Value
                    ELSE mvx.ISS2004Value 
                END AS RoomCatalogUnits,
                CASE 
                    WHEN ISNULL(@Manual, 'SOAT') = 'SOAT' THEN mvx.SOATArticle 
                    WHEN @Manual = 'ISS_2001'             THEN mvx.ISS2001Article
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
                    WHEN @Manual = 'SOAT' AND ex.StayCalendarDate < '2024-01-01'  THEN 'SMDLV'
                    WHEN @Manual = 'SOAT' AND ex.StayCalendarDate >= '2024-01-01' THEN 'UVB'
                    WHEN @Manual LIKE 'ISS%'                              THEN 'UVR' 
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
END;
GO