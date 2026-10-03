USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLCalculateCopay ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE {odata}.{COLCalculateCopay}
    @PatientVisit   NVARCHAR(50),
    @FacilityId     NVARCHAR(50),
    @ClaimGuid      NVARCHAR(50)  -- Restricts calculation to the specific claim
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @PatientFinancialClass VARCHAR(5) = 'A',
            @MaxAllowedCopayPerEvent DECIMAL(18,2) = 99999999.99,
            @PriorVisitLiability DECIMAL(18,2) = 0.00,
            @CurrentClaimLiability DECIMAL(18,2) = 0.00,
            @YearOfService INT;

    -- Extract patient financial class and admission year based on the visit
    SELECT TOP 1 
        @PatientFinancialClass = pat.FinancialClass,
        @YearOfService = YEAR(pvt.AdmitDateTime)
    FROM ClinicalGeniusEhr.dbo.PatientVisits pvt WITH(NOLOCK)
    INNER JOIN ClinicalGeniusEhr.dbo.PatientTable pat WITH(NOLOCK)
        ON pat.RecordUniqueId = pvt.PatientId
    WHERE pvt.PatientVisitUniqueId = @PatientVisit 
      AND pvt.FacilityId = @FacilityId;

    IF @YearOfService IS NULL SET @YearOfService = YEAR(GETDATE());

    -- Pre-load temporary Colombian statutory copay limits (Tope Máximo por Evento)
    IF OBJECT_ID('tempdb..#StatutoryCopayLimits') IS NOT NULL DROP TABLE #StatutoryCopayLimits;
    CREATE TABLE #StatutoryCopayLimits (
        CalendarYear INT, FinancialClass VARCHAR(5), MaxCapPerEvent DECIMAL(18,2)
    );

    INSERT INTO #StatutoryCopayLimits (CalendarYear, FinancialClass, MaxCapPerEvent)
    VALUES
        (2023, 'A', 304583.00), (2023, 'B', 1220455.00), (2023, 'C', 2440909.00), (2023, 'S1', 0.00),
        (2024, 'A', 338900.00), (2024, 'B', 1357600.00), (2024, 'C', 2715200.00), (2024, 'S1', 0.00),
        (2025, 'A', 370000.00), (2025, 'B', 1480000.00), (2025, 'C', 2960000.00), (2025, 'S1', 0.00),
        (2026, 'A', 400000.00), (2026, 'B', 1600000.00), (2026, 'C', 3200000.00), (2026, 'S1', 0.00);

    SELECT TOP 1 @MaxAllowedCopayPerEvent = scl.MaxCapPerEvent
    FROM #StatutoryCopayLimits scl WITH(NOLOCK)
    WHERE scl.CalendarYear = @YearOfService AND scl.FinancialClass = @PatientFinancialClass;

    IF @MaxAllowedCopayPerEvent IS NULL SET @MaxAllowedCopayPerEvent = 99999999.99;
    IF @PatientFinancialClass = 'S1' SET @MaxAllowedCopayPerEvent = 0.00;

    BEGIN TRY
        BEGIN TRAN;

        -- ==========================================================================================
        -- 1. Base Aggregation: Strictly restricted to the target @ClaimGuid
        -- ==========================================================================================
        UPDATE pyc
        SET pyc.MedicalCoinsurance = ROUND(ClaimTotals.TotalNet * (ISNULL(pyc.CoInsurance, 0.00) / 100.00), -2),
            pyc.PayerCoverageAmount = ROUND(ClaimTotals.TotalNet - ISNULL(pyc.Copay, 0.00) - ROUND(ClaimTotals.TotalNet * (ISNULL(pyc.CoInsurance, 0.00) / 100.00), -2), -2),
            pyc.LastUpdatedBy = 'CopayEngine_InitialAgg'
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc
        CROSS APPLY (
            SELECT ISNULL(SUM(pt.NetAmount), 0.00) AS TotalNet
            FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK)
            WHERE pt.ClaimGuid = @ClaimGuid
              AND pt.Status = 'Active'
              AND pt.Facility = @FacilityId
        ) ClaimTotals
        WHERE pyc.ClaimGuid = @ClaimGuid
          AND pyc.FacilityId = @FacilityId;

        -- ==========================================================================================
        -- 2. Event Evaluation: Sum prior finalized claims vs. current claim
        -- ==========================================================================================
        SELECT @PriorVisitLiability = ISNULL(SUM(ISNULL(Copay, 0.00) + ISNULL(MedicalCoinsurance, 0.00)), 0.00)
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims WITH(NOLOCK)
        WHERE PatientVisit = @PatientVisit 
          AND FacilityId = @FacilityId
          AND ClaimGuid != @ClaimGuid;

        SELECT @CurrentClaimLiability = ISNULL(Copay, 0.00) + ISNULL(MedicalCoinsurance, 0.00)
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims WITH(NOLOCK)
        WHERE ClaimGuid = @ClaimGuid
          AND FacilityId = @FacilityId;

        -- ==========================================================================================
        -- 3. Cap Enforcement: Trim current claim if the event cap is breached
        -- ==========================================================================================
        IF (@PriorVisitLiability + @CurrentClaimLiability) > @MaxAllowedCopayPerEvent
        BEGIN
            DECLARE @AvailableCapSpace DECIMAL(18,2) = @MaxAllowedCopayPerEvent - @PriorVisitLiability;
            IF @AvailableCapSpace < 0 SET @AvailableCapSpace = 0.00;

            UPDATE pyc
            SET pyc.Copay = ROUND(CASE WHEN pyc.Copay > @AvailableCapSpace THEN @AvailableCapSpace ELSE pyc.Copay END, -2),
                pyc.MedicalCoinsurance = ROUND(CASE WHEN pyc.Copay >= @AvailableCapSpace THEN 0.00 ELSE (@AvailableCapSpace - pyc.Copay) END, -2),
                pyc.PayerCoverageAmount = ROUND(pyc.PayerCoverageAmount + (@CurrentClaimLiability - @AvailableCapSpace), -2),
                pyc.LastUpdatedBy = 'CopayEngine_EventCapped'
            FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc
            WHERE pyc.ClaimGuid = @ClaimGuid
              AND pyc.FacilityId = @FacilityId;

            SELECT 'CLAIM CAPPED: Event limit reached, excess shifted to PayerCoverageAmount' AS AuditStatus;
        END
        ELSE
        BEGIN
            SELECT 'WITHIN LIMITS: Claim liability safely below event cap' AS AuditStatus;
        END;

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(), @ErrorSeverity INT = ERROR_SEVERITY(), @ErrorState INT = ERROR_STATE();
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH;
    
    IF OBJECT_ID('tempdb..#StatutoryCopayLimits') IS NOT NULL DROP TABLE #StatutoryCopayLimits;
END;
GO