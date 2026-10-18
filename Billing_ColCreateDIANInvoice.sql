USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLCreateDIANInvoice ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[COLCreateDIANInvoice]
    @FacilityId NVARCHAR(50),
    @PatientVisit NVARCHAR(50),
    @ClaimGuid NVARCHAR(50),
    @UserId NVARCHAR(100) = 'DianBillingEngine'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @InvoiceGuid NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50));
    DECLARE @InvoiceNumber NVARCHAR(20);
    DECLARE @ResolutionNumber NVARCHAR(50) = 'RES-DIAN-987654321'; -- To be replaced with dynamic DIAN config mapping
    DECLARE @PatientId NVARCHAR(50);
    DECLARE @PayerId NVARCHAR(50);
    DECLARE @IssueDateTime DATETIME = GETDATE();
    DECLARE @DueDate DATETIME = DATEADD(DAY, 30, GETDATE());
    
    DECLARE @GrossAmount DECIMAL(18,2) = 0.00;
    DECLARE @DiscountAmount DECIMAL(18,2) = 0.00;
    DECLARE @TaxableAmount DECIMAL(18,2) = 0.00;
    DECLARE @TaxAmount DECIMAL(18,2) = 0.00;
    DECLARE @CopayOrCuotaAmount DECIMAL(18,2) = 0.00;
    DECLARE @NetAmount DECIMAL(18,2) = 0.00;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ==========================================================================================
        -- 1. Extract Demographics & Payer Context (Bridged to Master Payers Table for NIT)
        -- ==========================================================================================
        SELECT TOP 1 
            @PatientId = pvt.PatientId,
            @PayerId = ISNULL(pyr.NIT, ISNULL(pyr.PayerId, '999999999'))
        FROM ClinicalGeniusEhr.dbo.PatientVisits pvt WITH(NOLOCK)
        INNER JOIN ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK) 
            ON pyc.PatientVisit = pvt.PatientVisitUniqueId
        INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
            ON ppy.PatientPayerGuid = pyc.PayerGuid
        INNER JOIN ClinicalGeniusEhr.dbo.InsurancePlans ip WITH(NOLOCK)
            ON ip.PlanGuid = ppy.PlanGuid
        INNER JOIN ClinicalGeniusEhr.dbo.Payers pyr WITH(NOLOCK)
            ON pyr.PayerGuid = ip.PayerGuid
        WHERE pyc.ClaimGuid = @ClaimGuid 
          AND pyc.FacilityId = @FacilityId;

        -- Fallback if not found in joins
        IF @PatientId IS NULL 
            SELECT TOP 1 @PatientId = PatientId FROM ClinicalGeniusEhr.dbo.PatientVisits WHERE PatientVisitUniqueId = @PatientVisit;
        IF @PayerId IS NULL 
            SET @PayerId = '999999999';

        -- ==========================================================================================
        -- 2. Aggregate Active Transactions (Strict DIAN Math via Quantity * Unit Price)
        -- ==========================================================================================
        SELECT 
            @GrossAmount = ISNULL(SUM(TransactionQuantity * PerItemChargeAmount), 0.00),
            @DiscountAmount = ISNULL(SUM(DiscountAmount), 0.00),
            @TaxableAmount = ISNULL(SUM((TransactionQuantity * PerItemChargeAmount) - ISNULL(DiscountAmount, 0.00)), 0.00), 
            @TaxAmount = ISNULL(SUM(TaxAmount), 0.00)
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(NOLOCK)
        WHERE ClaimGuid = @ClaimGuid
          AND Status = 'Active'
          AND Facility = @FacilityId
          AND PerItemChargeAmount > 0;

        -- ==========================================================================================
        -- 3. Extract Copay / Coinsurance to determine DIAN deductions
        -- ==========================================================================================
        SELECT TOP 1 
            @CopayOrCuotaAmount = ISNULL(Copay, 0.00) + ISNULL(MedicalCoinsurance, 0.00)
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims WITH(NOLOCK)
        WHERE ClaimGuid = @ClaimGuid 
          AND FacilityId = @FacilityId;

        -- ==========================================================================================
        -- 4. Calculate Net Amount (Strictly tying to DIAN validation math)
        -- ==========================================================================================
        SET @NetAmount = (@GrossAmount - @DiscountAmount + @TaxAmount) - @CopayOrCuotaAmount;

        -- Allocate Invoice Number (Placeholder pattern - requires mapping to your DIAN sequencer table)
        SET @InvoiceNumber = 'FE-' + LEFT(REPLACE(CAST(NEWID() AS VARCHAR(36)), '-', ''), 8);

        -- ==========================================================================================
        -- 5. Insert DIAN Invoice Header
        -- ==========================================================================================
        INSERT INTO ClinicalGeniusSupplyChain.dbo.DianInvoices (
            FacilityId, InvoiceGuid, InvoiceNumber, ResolutionNumber, PatientVisit, 
            ClaimGuid, PatientId, PayerId, IssueDateTime, DueDate, 
            OperationType, InvoiceType, GrossAmount, DiscountAmount, TaxableAmount, 
            TaxAmount, CopayOrCuotaAmount, NetAmount, DianStatus, 
            DateTimeEntered, LastUpdatedBy
        )
        VALUES (
            @FacilityId, @InvoiceGuid, @InvoiceNumber, @ResolutionNumber, @PatientVisit,
            @ClaimGuid, @PatientId, @PayerId, @IssueDateTime, @DueDate,
            '10', '01', @GrossAmount, @DiscountAmount, @TaxableAmount,
            @TaxAmount, @CopayOrCuotaAmount, @NetAmount, 'Draft',
            GETDATE(), @UserId
        );

        -- ==========================================================================================
        -- 6. Insert DIAN Invoice Lines (Realigned with standard DIAN UBL 2.1 Math)
        -- ==========================================================================================
        INSERT INTO ClinicalGeniusSupplyChain.dbo.DianInvoiceLines (
            FacilityId, InvoiceGuid, LineNumber, TransactionGuid, LineType, 
            ItemCode, ItemDescription, Quantity, UnitOfMeasure, 
            UnitPrice, LineGrossAmount, LineDiscountAmount, LineTaxableAmount, 
            LineTaxPercentage, LineTaxAmount, LineNetAmount
        )
        SELECT 
            pt.Facility, 
            @InvoiceGuid, 
            ROW_NUMBER() OVER(ORDER BY pt.DateTimeEntered ASC) AS LineNumber, 
            pt.TransactionGuid, 
            pt.TransactionType, 
            pt.CupsCode, 
            pt.SurgicalComponent, 
            pt.TransactionQuantity, 
            '94' AS UnitOfMeasure, 
            pt.PerItemChargeAmount, 
            (pt.TransactionQuantity * pt.PerItemChargeAmount) AS LineGrossAmount, 
            ISNULL(pt.DiscountAmount, 0.00) AS LineDiscountAmount, 
            ((pt.TransactionQuantity * pt.PerItemChargeAmount) - ISNULL(pt.DiscountAmount, 0.00)) AS LineTaxableAmount, 
            CASE WHEN pt.TaxAmount > 0 THEN 19.00 ELSE 0.00 END AS LineTaxPercentage, 
            ISNULL(pt.TaxAmount, 0.00) AS LineTaxAmount, 
            (((pt.TransactionQuantity * pt.PerItemChargeAmount) - ISNULL(pt.DiscountAmount, 0.00)) + ISNULL(pt.TaxAmount, 0.00)) AS LineNetAmount
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK)
        WHERE pt.ClaimGuid = @ClaimGuid 
          AND pt.Status = 'Active'
          AND pt.Facility = @FacilityId
          AND pt.PerItemChargeAmount > 0;

        -- Commit early to release write-locks before downstream tasks
        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrorSeverity INT = ERROR_SEVERITY(),
                @ErrorState INT = ERROR_STATE();
                
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH;
END;
GO