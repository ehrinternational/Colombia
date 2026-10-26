-- ==========================================================================================
-- DIAN ADJUSTMENT NOTES (CREDIT / DEBIT) PROCESSING ENGINE - MULTI-TENANT VER 3.0
-- TARGET ARCHITECTURE: SQL Server Enterprise 2014 / Node.js Orchestration
-- COMPLIANCE: COLOMBIAN DIAN NATIVE ANNEX 1.9 REGISTRY RULES
-- ==========================================================================================
USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLCreateDianAdjustmentNote ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[COLCreateDianAdjustmentNote]
    @SourceInvoiceGuid NVARCHAR(50),          
    @FacilityId NVARCHAR(50),                     
    @NoteType VARCHAR(5),                         
    @ReasonCode VARCHAR(5),                       
    @ReasonDescription NVARCHAR(250),             
    @AdjustmentGrossAmount DECIMAL(18,2),         
    @AdjustmentTaxAmount DECIMAL(18,2) = 0.00,
    @AdjustedBy NVARCHAR(100) = 'DianAdjustmentEngine'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SourceInvoiceGuid = LTRIM(RTRIM(@SourceInvoiceGuid));
    SET @FacilityId = LTRIM(RTRIM(@FacilityId));

    DECLARE @OrigInvoiceNumber NVARCHAR(20),
            @OrigPatientVisit NVARCHAR(50),
            @OrigClaimGuid NVARCHAR(50),
            @OrigPatientId NVARCHAR(50),
            @OrigPayerId NVARCHAR(50),
            @OrigCufe VARCHAR(100),
            @OrigResolution NVARCHAR(50),
            @NextNoteNumber NVARCHAR(20),
            @CurrentMaxId INT,
            @NotePrefix NVARCHAR(5);

    -- 1. TENANT-SAFE LOOKUP
    SELECT TOP 1
        @OrigInvoiceNumber = InvoiceNumber,
        @OrigPatientVisit = PatientVisit,
        @OrigClaimGuid = ClaimGuid,
        @OrigPatientId = PatientId,
        @OrigPayerId = PayerId,
        @OrigCufe = CUFE,
        @OrigResolution = ResolutionNumber
    FROM ClinicalGeniusSupplyChain.dbo.DianInvoices WITH(NOLOCK)
    WHERE InvoiceGuid = @SourceInvoiceGuid
      AND FacilityId = @FacilityId;

    IF @OrigPatientId IS NULL
    BEGIN
        RAISERROR('Validation Failure: Target InvoiceGuid does not exist or does not belong to this Facility / Tenant.', 16, 1);
        RETURN;
    END;

    IF @NoteType NOT IN ('91', '92')
    BEGIN
        RAISERROR('Validation Failure: NoteType must strictly be ''91'' (Credit) or ''92'' (Debit).', 16, 1);
        RETURN;
    END;

    IF @NoteType = '91'
    BEGIN
        SET @NotePrefix = 'NC'; 
    END
    ELSE
    BEGIN
        SET @NotePrefix = 'ND'; 
    END;

    BEGIN TRAN;
    BEGIN TRY
        
        -- 2. TENANT-ISOLATED SEQUENCE GENERATION
        SELECT @CurrentMaxId = ISNULL(MAX(CAST(SUBSTRING(InvoiceNumber, 3, 16) AS INT)), 100000)
        FROM ClinicalGeniusSupplyChain.dbo.DianInvoices WITH(XLOCK, ROWLOCK)
        WHERE InvoiceNumber LIKE @NotePrefix + '%'
          AND FacilityId = @FacilityId;
        
        SET @NextNoteNumber = @NotePrefix + CAST(@CurrentMaxId + 1 AS NVARCHAR(16));

        DECLARE @InsertedNote TABLE (NoteGuid NVARCHAR(50));

       -- 3. Header insertion
        INSERT INTO ClinicalGeniusSupplyChain.dbo.DianInvoices (
            FacilityId, SourceInvoiceGuid, ReasonCode, ReasonDescription,
            InvoiceNumber, ResolutionNumber, PatientVisit, ClaimGuid, PatientId, PayerId, 
            IssueDateTime, DueDate, OperationType, InvoiceType,
            GrossAmount, DiscountAmount, TaxableAmount, TaxAmount, 
            CopayOrCuotaAmount, NetAmount, DianStatus, LastUpdatedBy,
            ReferencedInvoiceNumber, ReferencedCUFE
        )
        OUTPUT inserted.InvoiceGuid INTO @InsertedNote
        VALUES (
            @FacilityId, @SourceInvoiceGuid, CAST(@ReasonCode AS INT), @ReasonDescription,
            @NextNoteNumber, @OrigResolution, @OrigPatientVisit, @OrigClaimGuid, @OrigPatientId, @OrigPayerId, 
            GETDATE(), GETDATE(), '20', @NoteType, 
            @AdjustmentGrossAmount, 0.00, @AdjustmentGrossAmount, @AdjustmentTaxAmount, 
            0.00, (@AdjustmentGrossAmount + @AdjustmentTaxAmount), 'Draft', @AdjustedBy,
            @OrigInvoiceNumber, @OrigCufe
        );

        DECLARE @NewNoteGuid NVARCHAR(50);
        SELECT TOP 1 @NewNoteGuid = NoteGuid FROM @InsertedNote;

       -- 4. Itemized line serialization
        INSERT INTO ClinicalGeniusSupplyChain.dbo.DianInvoiceLines (
            FacilityId, InvoiceGuid, LineNumber, TransactionGuid, LineType, ItemCode, 
            ItemDescription, Quantity, UnitOfMeasure, UnitPrice, LineGrossAmount, 
            LineDiscountAmount, LineTaxableAmount, LineTaxPercentage, LineTaxAmount, LineNetAmount
        )
        VALUES (
            @FacilityId, @NewNoteGuid, 1, NULL,
            CASE WHEN @NoteType = '91' THEN 'CreditNote' ELSE 'DebitNote' END,
            'AjusteFinanciero',
            CONCAT('Ajuste segun Motivo DIAN Tipo ', @ReasonCode, ': ', @ReasonDescription, ' | Ref: ', @OrigInvoiceNumber),
            1.0000, '94', @AdjustmentGrossAmount, @AdjustmentGrossAmount, 0.00,
            @AdjustmentGrossAmount, 
            CASE WHEN @AdjustmentTaxAmount > 0 THEN 19.00 ELSE 0.00 END, 
            @AdjustmentTaxAmount, (@AdjustmentGrossAmount + @AdjustmentTaxAmount)
        );

        COMMIT TRAN;

        -- Return output tokens back out to your Node.js application layer orchestration
        SELECT 
            @NewNoteGuid AS GeneratedNoteGuid, 
            @NextNoteNumber AS GeneratedNoteNumber, 
            @OrigInvoiceNumber AS ReferencedInvoiceNumber;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrorSeverity INT = ERROR_SEVERITY(),
                @ErrorState INT = ERROR_STATE();
                
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO