-- ==========================================================================================
-- DIAN ADJUSTMENT NOTES (CREDIT / DEBIT) PROCESSING ENGINE - MULTI-TENANT VER 3.0
-- TARGET ARCHITECTURE: SQL Server Enterprise 2014
-- COMPLIANCE: COLOMBIAN DIAN NATIVE ANNEX 1.9 REGISTRY RULES
-- ==========================================================================================
USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLCreateDianAdjustmentNote ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE {odata}.{COLCreateDianAdjustmentNote}
    @SourceInvoiceGuid NVARCHAR(50),          
    @FacilityId NVARCHAR(50),                     -- Mandatory tenant partition filter
    @NoteType VARCHAR(5),                         -- '91' for Nota Crédito, '92' for Nota Débito
    @ReasonCode VARCHAR(5),                       -- DIAN standard code
    @ReasonDescription NVARCHAR(250),             -- Text reason for the audit trail
    @AdjustmentGrossAmount DECIMAL(18,2),         
    @AdjustmentTaxAmount DECIMAL(18,2) = 0.00,
    @AdjustedBy NVARCHAR(100) = 'DianAdjustmentEngine'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Clean up parameter padding for SQL Server 2014 compatibility
    SET @SourceInvoiceGuid = LTRIM(RTRIM(@SourceInvoiceGuid));
    SET @FacilityId = LTRIM(RTRIM(@FacilityId));

    -- Initialize tracking state variables
    DECLARE @OrigInvoiceNumber NVARCHAR(20),
            @OrigPatientVisit NVARCHAR(50),
            @OrigClaimGuid NVARCHAR(50),
            @OrigPatientId NVARCHAR(50),
            @OrigPayerId NVARCHAR(50),
            @OrigCufe VARCHAR(100),
            @OrigResolution NVARCHAR(50),
            @NextNoteNumber NVARCHAR(20),
            @CurrentMaxId INT,
            @NotePrefix NVARCHAR(5),
            @TechnicalKey NVARCHAR(256);

    -- 1. TENANT-SAFE LOOKUP: Strictly validates GUID AND matching FacilityId boundary
    SELECT TOP 1
        @OrigInvoiceNumber = InvoiceNumber,
        @OrigPatientVisit = PatientVisit,
        @OrigClaimGuid = ClaimGuid,
        @OrigPatientId = PatientId,
        @OrigPayerId = PayerId,
        @OrigCufe = CUFE,
        @OrigResolution = ResolutionNumber
    FROM ClinicalGeniusSupplyChain.DianInvoices WITH(NOLOCK)
    WHERE InvoiceGuid = @SourceInvoiceGuid
      AND FacilityId = @FacilityId;

    -- Validation Safeguards
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

    -- Assign official prefixes based on DIAN specifications
    IF @NoteType = '91'
    BEGIN
        SET @NotePrefix = 'NC'; 
        SET @TechnicalKey = 'nc8957c3298a4115b04871e892c94311'; 
    END
    ELSE
    BEGIN
        SET @NotePrefix = 'ND'; 
        SET @TechnicalKey = 'nd8957c3298a4115b04871e892c94311'; 
    END;

    -- 2. TENANT-ISOLATED SEQUENCE GENERATION
    BEGIN TRAN;
    BEGIN TRY
        
        -- FIXED: Substring starting index corrected to 3 to safely capture digits following 'NC' or 'ND'
        SELECT @CurrentMaxId = ISNULL(MAX(CAST(SUBSTRING(InvoiceNumber, 3, 16) AS INT)), 100000)
        FROM ClinicalGeniusSupplyChain.DianInvoices WITH(XLOCK, ROWLOCK)
        WHERE InvoiceNumber LIKE @NotePrefix + '%'
          AND FacilityId = @FacilityId;
        
        SET @NextNoteNumber = @NotePrefix + CAST(@CurrentMaxId + 1 AS NVARCHAR(16));

        -- Anchor block memory holder to extract identity scopes
        DECLARE @InsertedNote TABLE (NoteGuid NVARCHAR(50));

        -- 3. Header insertion mapping the V3 Table constraints layout
        -- NOTE: Ensure ReferencedInvoiceNumber and AdjustmentReasonCode exist in the schema.
        INSERT INTO ClinicalGeniusSupplyChain.DianInvoices (
            InvoiceNumber, ResolutionNumber, FacilityId, PatientVisit, ClaimGuid, PatientId, PayerId, 
            IssueDateTime, DueDate, GrossAmount, DiscountAmount, TaxableAmount, TaxAmount, 
            CopayOrCuotaAmount, NetAmount, InvoiceType, OperationType, DianStatus, LastUpdatedBy,
            DianResponseDescription,
            ReferencedInvoiceNumber,  
            AdjustmentReasonCode      
        )
        OUTPUT inserted.InvoiceGuid INTO @InsertedNote
        VALUES (
            @NextNoteNumber,
            @OrigResolution,
            @FacilityId, 
            @OrigPatientVisit,
            @OrigClaimGuid,
            @OrigPatientId,
            @OrigPayerId,
            GETDATE(),
            GETDATE(), 
            @AdjustmentGrossAmount,
            0.00,
            @AdjustmentGrossAmount,
            @AdjustmentTaxAmount,
            0.00,
            (@AdjustmentGrossAmount + @AdjustmentTaxAmount),
            @NoteType,          
            '20',               
            'Draft',
            @AdjustedBy,
            CONCAT('Reason Code: ', @ReasonCode, ' | ', @ReasonDescription),
            @OrigInvoiceNumber,       
            @ReasonCode               
        );

        DECLARE @NewNoteGuid NVARCHAR(50);
        SELECT TOP 1 @NewNoteGuid = NoteGuid FROM @InsertedNote;

        -- 4. Itemized line serialization pass
        INSERT INTO ClinicalGeniusSupplyChain.DianInvoiceLines (
            InvoiceGuid, LineNumber, TransactionGuid, LineType, ItemCode, 
            ItemDescription, Quantity, UnitOfMeasure, UnitPrice, LineGrossAmount, 
            LineDiscountAmount, LineTaxableAmount, LineTaxPercentage, LineTaxAmount, LineNetAmount
        )
        VALUES (
            @NewNoteGuid,
            1, 
            NULL,
            CASE WHEN @NoteType = '91' THEN 'CreditNote' ELSE 'DebitNote' END,
            'AjusteFinanciero',
            CONCAT('Ajuste segun Motivo DIAN Tipo ', @ReasonCode, ': ', @ReasonDescription, ' | Ref: ', @OrigInvoiceNumber),
            1.0000,
            '94', 
            @AdjustmentGrossAmount,
            @AdjustmentGrossAmount,
            0.00,
            @AdjustmentGrossAmount,
            0.00,
            @AdjustmentTaxAmount,
            (@AdjustmentGrossAmount + @AdjustmentTaxAmount)
        );

        -- ==========================================================================================
        -- 5. CRYPTOGRAPHIC EVALUATION LAYER: Formulate the DIAN CUDE Hash
        -- ==========================================================================================
        UPDATE inv
        SET inv.CUFE = LOWER(
                CONVERT(VARCHAR(96), 
                    HASHBYTES('SHA_384', 
                        inv.InvoiceNumber + 
                        CONVERT(VARCHAR(10), inv.IssueDateTime, 120) + 
                        CONVERT(VARCHAR(8), inv.IssueDateTime, 108) + '-05:00' + 
                        CAST(CAST(inv.GrossAmount AS DECIMAL(18,2)) AS VARCHAR(20)) + 
                        '01' + 
                        CAST(CAST(inv.TaxAmount AS DECIMAL(18,2)) AS VARCHAR(20)) + 
                        CAST(CAST(inv.NetAmount AS DECIMAL(18,2)) AS VARCHAR(20)) + 
                        '900123456' + 
                        inv.PayerId + 
                        @TechnicalKey + '1' + 
                        ISNULL(@OrigCufe, '') 
                    ), 
                2)
            ),
            inv.QrCodeUrl = 'https://dian.gov.co' + 
                            LOWER(CONVERT(VARCHAR(96), HASHBYTES('SHA_384', inv.InvoiceNumber + CONVERT(VARCHAR(10), inv.IssueDateTime, 120) + @TechnicalKey), 2))
        FROM ClinicalGeniusSupplyChain.DianInvoices inv
        WHERE inv.InvoiceGuid = @NewNoteGuid;

        COMMIT TRAN;

        -- Return output tokens back out to your Node.js application layer orchestration
        SELECT @NewNoteGuid AS GeneratedNoteGuid, @NextNoteNumber AS GeneratedNoteNumber, @OrigInvoiceNumber AS ReferencedInvoiceNumber;

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