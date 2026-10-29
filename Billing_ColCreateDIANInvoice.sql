USE [ClinicalGeniusSupplyChain]
GO

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
    DECLARE @InvoicePrefix NVARCHAR(5);
    DECLARE @InvoiceNumber NVARCHAR(20);
    DECLARE @ResolutionNumber NVARCHAR(50) = 'RES-DIAN-987654321'; 
    DECLARE @PatientId NVARCHAR(50);
    DECLARE @PayerId NVARCHAR(50);
    
    DECLARE @IssueDateTime DATETIMEOFFSET = SYSDATETIMEOFFSET(); 
    DECLARE @DueDate DATETIME = DATEADD(DAY, 30, GETDATE());
    
    DECLARE @GrossAmount DECIMAL(18,2) = 0.00;
    DECLARE @DiscountAmount DECIMAL(18,2) = 0.00;
    DECLARE @TaxableAmount DECIMAL(18,2) = 0.00;
    DECLARE @TaxAmount DECIMAL(18,2) = 0.00;
    DECLARE @CopayOrCuotaAmount DECIMAL(18,2) = 0.00;
    DECLARE @NetAmount DECIMAL(18,2) = 0.00;
    DECLARE @CUDE VARCHAR(100) = NULL;

    -- Temporary table holding the exact locked rows for this invoice batch
    DECLARE @LockedTransactions TABLE (
        Facility NVARCHAR(50),
        TransactionGuid NVARCHAR(50),
        TransactionType NVARCHAR(50),
        CupsCode NVARCHAR(50),
        SurgicalComponent NVARCHAR(500),
        TransactionQuantity DECIMAL(18,2),
        NetAmount DECIMAL(18,4),
        DiscountAmount DECIMAL(18,4),
        TaxAmount DECIMAL(18,4),
        DispensingValue DECIMAL(18,2),
        DateTimeEntered DATETIME
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ==========================================================================================
        -- 1. Extract Demographics & Payer Context
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

        IF @PatientId IS NULL 
            SELECT TOP 1 @PatientId = PatientId FROM ClinicalGeniusEhr.dbo.PatientVisits WHERE PatientVisitUniqueId = @PatientVisit;
        IF @PayerId IS NULL 
            SET @PayerId = '999999999';

        -- ==========================================================================================
        -- 2. STAMP & EXTRACT: Filter valid transactions and lock them
        -- ==========================================================================================
        UPDATE ClinicalGeniusSupplyChain.dbo.PatientTransactions
        SET 
            DIANInvoiceBatchId = @InvoiceGuid,
            CurrentWorkflowStatus = 'Batched for DIAN'
        OUTPUT 
            INSERTED.Facility,
            INSERTED.TransactionGuid,
            INSERTED.TransactionType,
            INSERTED.CupsCode,
            INSERTED.SurgicalComponent,
            INSERTED.TransactionQuantity,
            INSERTED.NetAmount,
            INSERTED.DiscountAmount,
            INSERTED.TaxAmount,
            INSERTED.DispensingValue,
            INSERTED.DateTimeEntered
        INTO @LockedTransactions
        WHERE ClaimGuid = @ClaimGuid
          AND Status = 'Active'
          AND Facility = @FacilityId
          AND NetAmount > 0
          AND DIANInvoiceBatchId IS NULL
          AND (
              TransactionType <> 'Honorary' 
              OR (TransactionType = 'Honorary' AND CurrentWorkflowStatus = 'Approved')
          );

        -- ==========================================================================================
        -- 3. Aggregate Active Transactions (Inclusive of Dispensing Fees)
        -- ==========================================================================================
        SELECT 
            @GrossAmount = ISNULL(SUM(NetAmount), 0.00),
            @DiscountAmount = ISNULL(SUM(DiscountAmount), 0.00),
            @TaxableAmount = ISNULL(SUM(NetAmount - ISNULL(DiscountAmount, 0.00)), 0.00), 
            @TaxAmount = ISNULL(SUM(TaxAmount), 0.00)
        FROM @LockedTransactions;

        -- ==========================================================================================
        -- 4. Extract Copay / Coinsurance
        -- ==========================================================================================
        SELECT TOP 1 
            @CopayOrCuotaAmount = ISNULL(Copay, 0.00) + ISNULL(MedicalCoinsurance, 0.00)
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims WITH(NOLOCK)
        WHERE ClaimGuid = @ClaimGuid 
          AND FacilityId = @FacilityId;

        SET @NetAmount = (@GrossAmount - @DiscountAmount + @TaxAmount) - @CopayOrCuotaAmount;

        SET @InvoicePrefix = 'FE';
        SET @InvoiceNumber = LEFT(REPLACE(CAST(NEWID() AS VARCHAR(36)), '-', ''), 8);

        -- ==========================================================================================
        -- 5. Insert DIAN Invoice Header
        -- ==========================================================================================
        INSERT INTO ClinicalGeniusSupplyChain.dbo.DianInvoices (
            FacilityId, InvoiceGuid, InvoicePrefix, InvoiceNumber, ResolutionNumber, PatientVisit, 
            ClaimGuid, PatientId, PayerId, IssueDateTime, DueDate, 
            OperationType, InvoiceType, GrossAmount, DiscountAmount, TaxableAmount, 
            TaxAmount, CopayOrCuotaAmount, NetAmount, CUDE, DianStatus, 
            DateTimeEntered, LastUpdatedBy
        )
        VALUES (
            @FacilityId, @InvoiceGuid, @InvoicePrefix, @InvoiceNumber, @ResolutionNumber, @PatientVisit,
            @ClaimGuid, @PatientId, @PayerId, @IssueDateTime, @DueDate,
            '10', '01', @GrossAmount, @DiscountAmount, @TaxableAmount,
            @TaxAmount, @CopayOrCuotaAmount, @NetAmount, @CUDE, 'Draft',
            GETDATE(), @UserId
        );

        -- ==========================================================================================
        -- 6. Insert DIAN Invoice Lines
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
            CASE WHEN pt.TransactionQuantity > 0 THEN (pt.NetAmount / pt.TransactionQuantity) ELSE pt.NetAmount END AS UnitPrice, 
            pt.NetAmount AS LineGrossAmount, 
            ISNULL(pt.DiscountItemAmount, 0.00) AS LineDiscountAmount, 
            (pt.NetAmount - ISNULL(pt.DiscountAmount, 0.00)) AS LineTaxableAmount, 
            CASE WHEN pt.TaxAmount > 0 THEN 19.00 ELSE 0.00 END AS LineTaxPercentage, 
            ISNULL(pt.TaxAmount, 0.00) AS LineTaxAmount, 
            ((pt.NetAmount - ISNULL(pt.DiscountAmount, 0.00)) + ISNULL(pt.TaxAmount, 0.00)) AS LineNetAmount
        FROM @LockedTransactions pt;
          
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