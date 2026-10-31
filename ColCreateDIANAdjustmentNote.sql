SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'[dbo].[COLCreateDianAdjustmentNote]', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE [dbo].[COLCreateDianAdjustmentNote] AS BEGIN SET NOCOUNT ON; END');
GO

-- ==========================================================================================
-- Procedure: [dbo].[COLCreateDianAdjustmentNote]
-- Purpose: Atomically validates the referenced DIAN sales invoice, generates a consecutive
--          tenant-isolated NC/ND number, and inserts the UBL 2.1 header and adjustment line.
-- Target: SQL Server 2014+
-- ==========================================================================================
ALTER PROCEDURE [dbo].[COLCreateDianAdjustmentNote]
    @SourceInvoiceGuid     NVARCHAR(50),
    @FacilityId            NVARCHAR(50),
    @NoteType              VARCHAR(5),
    @ReasonCode            VARCHAR(5),
    @ReasonDescription     NVARCHAR(250),
    @AdjustmentGrossAmount DECIMAL(18,2),
    @AdjustmentTaxAmount   DECIMAL(18,2) = 0.00,
    @AdjustedBy            NVARCHAR(100) = N'DianAdjustmentEngine'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SourceInvoiceGuid = LTRIM(RTRIM(@SourceInvoiceGuid));
    SET @FacilityId = LTRIM(RTRIM(@FacilityId));
    SET @NoteType = LTRIM(RTRIM(@NoteType));
    SET @ReasonCode = LTRIM(RTRIM(@ReasonCode));
    SET @ReasonDescription = LTRIM(RTRIM(@ReasonDescription));
    SET @AdjustedBy = ISNULL(NULLIF(LTRIM(RTRIM(@AdjustedBy)), N''), N'DianAdjustmentEngine');
    SET @AdjustmentTaxAmount = ROUND(ISNULL(@AdjustmentTaxAmount, 0.00), 2);
    SET @AdjustmentGrossAmount = ROUND(@AdjustmentGrossAmount, 2);

    IF NULLIF(@SourceInvoiceGuid, N'') IS NULL
        THROW 50001, N'Validation Failure: @SourceInvoiceGuid is required.', 1;

    IF NULLIF(@FacilityId, N'') IS NULL
        THROW 50002, N'Validation Failure: @FacilityId is required.', 1;

    IF @NoteType NOT IN ('91', '92')
        THROW 50003, N'Validation Failure: NoteType must strictly be ''91'' (Credit) or ''92'' (Debit).', 1;

    DECLARE @ParsedReasonCode INT = TRY_CAST(@ReasonCode AS INT);
    IF @ParsedReasonCode IS NULL OR @ParsedReasonCode <= 0
        THROW 50004, N'Validation Failure: @ReasonCode must be a positive integer DIAN concept code.', 1;

    IF NULLIF(@ReasonDescription, N'') IS NULL
        THROW 50005, N'Validation Failure: @ReasonDescription is required.', 1;

    IF @AdjustmentGrossAmount IS NULL OR @AdjustmentGrossAmount <= 0.00
        THROW 50006, N'Validation Failure: @AdjustmentGrossAmount must be greater than zero.', 1;

    IF @AdjustmentTaxAmount < 0.00
        THROW 50007, N'Validation Failure: @AdjustmentTaxAmount cannot be negative.', 1;

    DECLARE @NotePrefix NVARCHAR(5) = CASE WHEN @NoteType = '91' THEN N'NC' ELSE N'ND' END;
    DECLARE @OperationType VARCHAR(5) = CASE WHEN @NoteType = '91' THEN '20' ELSE '30' END;

    DECLARE @OrigInvoiceNumber NVARCHAR(20),
            @OrigPatientVisit NVARCHAR(50),
            @OrigClaimGuid NVARCHAR(50),
            @OrigPatientId NVARCHAR(50),
            @OrigPayerId NVARCHAR(50),
            @OrigCufe VARCHAR(100),
            @OrigResolution NVARCHAR(50),
            @OrigInvoiceType VARCHAR(5),
            @OrigDianStatus NVARCHAR(50),
            @OrigGrossAmount DECIMAL(18,2),
            @OrigDiscountAmount DECIMAL(18,2),
            @OrigTaxAmount DECIMAL(18,2);

    DECLARE @TranCount INT = @@TRANCOUNT;
    DECLARE @LockResource NVARCHAR(255) = N'DIAN_SEQ:' + @FacilityId + N':' + @NotePrefix;
    DECLARE @LockResult INT;
    DECLARE @CurrentMaxId BIGINT;
    DECLARE @NextNoteNumber NVARCHAR(20);
    DECLARE @NewNoteGuid NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50));

    DECLARE @IssueDateTime DATETIMEOFFSET(7) = SWITCHOFFSET(SYSDATETIMEOFFSET(), '-05:00');
    DECLARE @DueDate DATETIME = CAST(@IssueDateTime AS DATETIME);
    DECLARE @TaxableAmount DECIMAL(18,2) = CASE WHEN @AdjustmentTaxAmount > 0.00 THEN @AdjustmentGrossAmount ELSE 0.00 END;
    DECLARE @LineTaxPercentage DECIMAL(18,2) = CASE
        WHEN @AdjustmentTaxAmount > 0.00 THEN ROUND((@AdjustmentTaxAmount / @AdjustmentGrossAmount) * 100.0, 2)
        ELSE 0.00
    END;
    DECLARE @NetAmount DECIMAL(18,2) = @AdjustmentGrossAmount + @AdjustmentTaxAmount;

    BEGIN TRY
        IF @TranCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION sp_COLCreateDianAdjustmentNote;

        -- 1. Lock and validate the source invoice under tenant isolation
        SELECT TOP (1)
            @OrigInvoiceNumber = InvoiceNumber,
            @OrigPatientVisit = PatientVisit,
            @OrigClaimGuid = ClaimGuid,
            @OrigPatientId = PatientId,
            @OrigPayerId = PayerId,
            @OrigCufe = CUFE,
            @OrigResolution = ResolutionNumber,
            @OrigInvoiceType = InvoiceType,
            @OrigDianStatus = DianStatus,
            @OrigGrossAmount = ISNULL(GrossAmount, 0.00),
            @OrigDiscountAmount = ISNULL(DiscountAmount, 0.00),
            @OrigTaxAmount = ISNULL(TaxAmount, 0.00)
        FROM [dbo].[DianInvoices] WITH (UPDLOCK, HOLDLOCK)
        WHERE InvoiceGuid = @SourceInvoiceGuid
          AND FacilityId = @FacilityId;

        IF @@ROWCOUNT = 0 OR @OrigPatientId IS NULL
            THROW 50008, N'Validation Failure: Target InvoiceGuid does not exist or does not belong to this Facility / Tenant.', 1;

        IF @OrigInvoiceType <> '01'
            THROW 50009, N'Validation Failure: Adjustment notes can only reference a sales invoice (InvoiceType ''01'').', 1;

        IF ISNULL(@OrigDianStatus, N'') IN (N'Cancelled', N'Voided', N'Rejected')
            THROW 50010, N'Validation Failure: Cannot issue an adjustment note against a cancelled, voided, or rejected invoice.', 1;

        IF @NoteType = '91'
        BEGIN
            DECLARE @ExistingCreditedTotal DECIMAL(18,2) = 0.00;
            SELECT @ExistingCreditedTotal = ISNULL(SUM(ISNULL(GrossAmount, 0.00) - ISNULL(DiscountAmount, 0.00) + ISNULL(TaxAmount, 0.00)), 0.00)
            FROM [dbo].[DianInvoices] WITH (UPDLOCK, HOLDLOCK)
            WHERE SourceInvoiceGuid = @SourceInvoiceGuid
              AND FacilityId = @FacilityId
              AND InvoiceType = '91'
              AND ISNULL(DianStatus, N'') NOT IN (N'Cancelled', N'Voided', N'Rejected');

            DECLARE @MaxCreditableAmount DECIMAL(18,2) = (@OrigGrossAmount - @OrigDiscountAmount) + @OrigTaxAmount;
            IF (@ExistingCreditedTotal + @NetAmount) > @MaxCreditableAmount
                THROW 50011, N'Validation Failure: Cumulative credit notes exceed the total value of the referenced invoice.', 1;
        END

        -- 2. Serialize sequence generation per Facility + NotePrefix
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = N'Exclusive',
            @LockOwner = N'Transaction',
            @LockTimeout = 15000;

        IF @LockResult < 0
            THROW 50012, N'Timeout acquiring sequence lock for DIAN adjustment note numbering.', 1;

        SELECT @CurrentMaxId = ISNULL(
            MAX(TRY_CAST(SUBSTRING(InvoiceNumber, LEN(@NotePrefix) + 1, 20) AS BIGINT)),
            100000
        )
        FROM [dbo].[DianInvoices] WITH (UPDLOCK, HOLDLOCK)
        WHERE FacilityId = @FacilityId
          AND InvoiceNumber LIKE @NotePrefix + N'%'
          AND LEN(InvoiceNumber) > LEN(@NotePrefix)
          AND SUBSTRING(InvoiceNumber, LEN(@NotePrefix) + 1, 20) NOT LIKE N'%[^0-9]%';

        SET @NextNoteNumber = @NotePrefix + CAST(@CurrentMaxId + 1 AS NVARCHAR(15));

        -- 3. Insert adjustment note header
        INSERT INTO [dbo].[DianInvoices] (
            FacilityId, InvoiceGuid, InvoicePrefix, SourceInvoiceGuid, ReasonCode, ReasonDescription,
            InvoiceNumber, ResolutionNumber, PatientVisit, ClaimGuid, PatientId, PayerId,
            IssueDateTime, DueDate, OperationType, InvoiceType,
            GrossAmount, DiscountAmount, TaxableAmount, TaxAmount,
            CopayOrCuotaAmount, NetAmount, CUFE, CUDE, DianStatus,
            DateTimeEntered, LastUpdatedBy, ReferencedInvoiceNumber, ReferencedCUFE
        )
        VALUES (
            @FacilityId, @NewNoteGuid, @NotePrefix, @SourceInvoiceGuid, @ParsedReasonCode, @ReasonDescription,
            @NextNoteNumber, @OrigResolution, @OrigPatientVisit, @OrigClaimGuid, @OrigPatientId, @OrigPayerId,
            @IssueDateTime, @DueDate, @OperationType, @NoteType,
            @AdjustmentGrossAmount, 0.00, @TaxableAmount, @AdjustmentTaxAmount,
            0.00, @NetAmount, NULL, NULL, N'Draft',
            SYSDATETIME(), @AdjustedBy, @OrigInvoiceNumber, @OrigCufe
        );

        -- 4. Insert itemized adjustment line
        INSERT INTO [dbo].[DianInvoiceLines] (
            FacilityId, InvoiceGuid, LineNumber, TransactionGuid, LineType, ItemCode,
            ItemDescription, Quantity, UnitOfMeasure, UnitPrice, LineGrossAmount,
            LineDiscountAmount, LineTaxableAmount, LineTaxPercentage, LineTaxAmount, LineNetAmount
        )
        VALUES (
            @FacilityId, @NewNoteGuid, 1, NULL,
            CASE WHEN @NoteType = '91' THEN N'CreditNote' ELSE N'DebitNote' END,
            N'AjusteFinanciero',
            CONCAT(N'Ajuste segun Motivo DIAN Tipo ', @ReasonCode, N': ', @ReasonDescription, N' | Ref: ', @OrigInvoiceNumber),
            1.0000, '94', @AdjustmentGrossAmount, @AdjustmentGrossAmount, 0.00,
            @TaxableAmount, @LineTaxPercentage, @AdjustmentTaxAmount, @NetAmount
        );

        IF @TranCount = 0
            COMMIT TRANSACTION;

        SELECT
            @NewNoteGuid AS GeneratedNoteGuid,
            @NextNoteNumber AS GeneratedNoteNumber,
            @OrigInvoiceNumber AS ReferencedInvoiceNumber;
    END TRY
    BEGIN CATCH
        IF @TranCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @TranCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_COLCreateDianAdjustmentNote;

        THROW;
    END CATCH
END;
GO