CREATE OR ALTER PROCEDURE ClinicalGeniusSupplyChain.dbo.CalculateCopays
    @PatientVisit   NVARCHAR(50),
    @FacilityId     NVARCHAR(50),
    @PatientId      NVARCHAR(50),
    @ClaimGuid      NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PatientFinancialClass VARCHAR(5) = 'A',
            @MaxAllowedCopayPerEvent DECIMAL(18,2) = 99999999.99,
            @CurrentCalculatedVisitCopay DECIMAL(18,2) = 0.00;

    -- Extract patient financial class
    SELECT TOP 1 
        @PatientFinancialClass = pat.FinancialClass
    FROM ClinicalGeniusEhr.dbo.PatientTable pat WITH(NOLOCK)
    WHERE pat.PatientId = @PatientId;

    -- Extract statutory co-payment cap limit for current fiscal year
    SELECT TOP 1 
        @MaxAllowedCopayPerEvent = scl.MaxCapPerEvent
    FROM ClinicalGeniusSupplyChain.dbo.StatutoryCopayLimits scl WITH(NOLOCK)
    WHERE scl.CalendarYear = YEAR(GETDATE())
      AND scl.FinancialClass = @PatientFinancialClass;

    IF @MaxAllowedCopayPerEvent IS NULL
        SET @MaxAllowedCopayPerEvent = 99999999.99;

    -- Calculate current patient out-of-pocket liabilities recorded on the claim
    SELECT TOP 1
        @CurrentCalculatedVisitCopay = ISNULL(pyc.Copay, 0.00) + ISNULL(pyc.MedicalCoinsurance, 0.00)
    FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
    WHERE pyc.ClaimGuid = @ClaimGuid
      AND pyc.FacilityId = @FacilityId;

    -- Enforce statutory cap and shift excess balance to payer coverage
    IF @CurrentCalculatedVisitCopay > @MaxAllowedCopayPerEvent
    BEGIN
        UPDATE pyc
        SET pyc.Copay = CASE WHEN @PatientFinancialClass = 'S1' THEN 0.00 ELSE @MaxAllowedCopayPerEvent END,
            pyc.MedicalCoinsurance = 0.00,
            pyc.PayerCoverageAmount = pyc.PayerCoverageAmount + (@CurrentCalculatedVisitCopay - @MaxAllowedCopayPerEvent),
            pyc.LastUpdatedBy = 'CopayCappingMatrix'
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc
        WHERE pyc.ClaimGuid = @ClaimGuid
          AND pyc.FacilityId = @FacilityId;

        SELECT 'CO-PAYMENT CAPPED: Excess shifted to insurer' AS AuditStatus;
    END
    ELSE
    BEGIN
        SELECT 'CO-PAYMENT WITHIN LEGAL LIMITS: No shift required' AS AuditStatus;
    END;
END;
GO