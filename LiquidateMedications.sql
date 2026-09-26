CREATE OR ALTER PROCEDURE ClinicalGeniusSupplyChain.dbo.LiquidateMedications
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

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ==========================================================================================
        -- 2. Targeted Staging Clear (Medications ONLY)
        -- ==========================================================================================
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(ROWLOCK, UPDLOCK)
        SET Status = 'Canceled',
            DateTimeLastUpdated = GETDATE(),
            LastUpdatedBy = 'PricingEngine_Medications'
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND TransactionType = 'Medication'
          AND Status <> 'Canceled'
          AND (ElectronicInvoiceStatus IS NULL OR ElectronicInvoiceStatus <> 'Transmitted');

        -- ==========================================================================================
        -- 3. Execution Pipeline Matrix
        -- ==========================================================================================
        ;WITH ActiveMedicationList AS (
            SELECT 
                mar.PatientId, 
                mar.PatientVisit, 
                mar.MedicationCode, 
                mar.MedicationName, 
                mar.ActualDoseGiven, 
                mar.QuantityUnit, 
                mar.Facility,
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
                -- Restrict 25% premium strictly to Sundays and legal holidays
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
                ISNULL(ce.PriceModifier, 0.00) AS PriceModifier, 
                ce.ExceptionGuid,
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

        COMMIT TRANSACTION;
        SELECT 'MEDICATIONS LIQUIDATED SUCCESSFULLY' AS ExecutionStatus;

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
END;
GO