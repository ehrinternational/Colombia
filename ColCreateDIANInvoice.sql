SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'[dbo].[COLCreateDIANInvoice]', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE [dbo].[COLCreateDIANInvoice] AS BEGIN SET NOCOUNT ON; END');
GO

-- ==========================================================================================
-- Procedure: [dbo].[COLCreateDIANInvoice]
-- Purpose: Locks eligible active PatientTransactions for a claim, reconciles inclusive
--          NetAmount charges, discounts, IVA, and copays, and generates a DIAN UBL 2.1
--          invoice with exact monetary parity for COLCreateRipsRecord.
-- Target: SQL Server 2014+
-- ==========================================================================================
ALTER PROCEDURE [dbo].[COLCreateDIANInvoice]
    @FacilityId       NVARCHAR(50),
    @PatientVisit     NVARCHAR(50),
    @ClaimGuid        NVARCHAR(50),
    @UserId           NVARCHAR(100) = N'DianBillingEngine',
    @InvoicePrefix    NVARCHAR(5)   = N'FE',
    @ResolutionNumber NVARCHAR(50)  = N'RES-DIAN-987654321'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @FacilityId = LTRIM(RTRIM(@FacilityId));
    SET @PatientVisit = NULLIF(LTRIM(RTRIM(@PatientVisit)), N'');
    SET @ClaimGuid = LTRIM(RTRIM(@ClaimGuid));
    SET @UserId = ISNULL(NULLIF(LTRIM(RTRIM(@UserId)), N''), N'DianBillingEngine');
    SET @InvoicePrefix = ISNULL(NULLIF(LTRIM(RTRIM(@InvoicePrefix)), N''), N'FE');
    SET @ResolutionNumber = ISNULL(NULLIF(LTRIM(RTRIM(@ResolutionNumber)), N''), N'RES-DIAN-987654321');

    IF NULLIF(@FacilityId, N'') IS NULL
        THROW 50001, N'Validation Failure: @FacilityId is required.', 1;

    IF NULLIF(@ClaimGuid, N'') IS NULL
        THROW 50002, N'Validation Failure: @ClaimGuid is required.', 1;

    DECLARE @TranCount INT = @@TRANCOUNT;
    DECLARE @InvoiceGuid NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50));
    DECLARE @InvoiceNumber NVARCHAR(20);
    DECLARE @LockResource NVARCHAR(255) = N'DIAN_SEQ:' + @FacilityId + N':' + @InvoicePrefix;
    DECLARE @LockResult INT;
    DECLARE @CurrentMaxId BIGINT;

    DECLARE @ClaimVisitId NVARCHAR(50);
    DECLARE @EffectiveVisit NVARCHAR(50);
    DECLARE @PatientId NVARCHAR(50);
    DECLARE @PayerId NVARCHAR(50);

    DECLARE @IssueDateTime DATETIMEOFFSET(7) = SWITCHOFFSET(SYSDATETIMEOFFSET(), '-05:00');
    DECLARE @DueDate DATETIME = DATEADD(DAY, 30, CAST(@IssueDateTime AS DATETIME));

    DECLARE @GrossAmount DECIMAL(18,2) = 0.00;
    DECLARE @DiscountAmount DECIMAL(18,2) = 0.00;
    DECLARE @TaxableAmount DECIMAL(18,2) = 0.00;
    DECLARE @TaxAmount DECIMAL(18,2) = 0.00;
    DECLARE @CopayOrCuotaAmount DECIMAL(18,2) = 0.00;
    DECLARE @NetAmount DECIMAL(18,2) = 0.00;

    DECLARE @LockedTransactions TABLE (
        Facility            NVARCHAR(50),
        TransactionGuid     NVARCHAR(50),
        TransactionType     NVARCHAR(50),
        CupsCode            NVARCHAR(50),
        SurgicalComponent   NVARCHAR(500),
        TransactionQuantity DECIMAL(18,4),
        PerItemChargeAmount DECIMAL(18,4),
        TaxRate             DECIMAL(18,8),
        NetAmount           DECIMAL(18,4),
        DiscountAmount      DECIMAL(18,4),
        TaxAmount           DECIMAL(18,4),
        DispensingValue     DECIMAL(18,2),
        DateTimeEntered     DATETIME
    );

    DECLARE @CalculatedLines TABLE (
        Facility            NVARCHAR(50),
        LineNumber          INT,
        TransactionGuid     NVARCHAR(50),
        LineType            NVARCHAR(50),
        ItemCode            NVARCHAR(50),
        ItemDescription     NVARCHAR(500),
        Quantity            DECIMAL(18,4),
        UnitOfMeasure       VARCHAR(10),
        UnitPrice           DECIMAL(18,4),
        LineGrossAmount     DECIMAL(18,2),
        LineDiscountAmount  DECIMAL(18,2),
        LineTaxableAmount   DECIMAL(18,2),
        LineTaxPercentage   DECIMAL(18,2),
        LineTaxAmount       DECIMAL(18,2),
        LineNetAmount       DECIMAL(18,2)
    );

    BEGIN TRY
        IF @TranCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION sp_COLCreateDIANInvoice;

        -- 1. Validate Claim, Visit, Patient, Payer NIT, and Copay/Coinsurance
        SELECT TOP (1)
            @ClaimVisitId = pyc.PatientVisit,
            @PatientId = pvt.PatientId,
            @PayerId = COALESCE(
                NULLIF(LTRIM(RTRIM(pyr.NIT)), N''),
                NULLIF(LTRIM(RTRIM(pyr.PayerId)), N''),
                N'999999999'
            ),
            @CopayOrCuotaAmount = ROUND(ISNULL(pyc.Copay, 0.00) + ISNULL(pyc.MedicalCoinsurance, 0.00), 2)
        FROM [dbo].[PayerClaims] pyc WITH (UPDLOCK, ROWLOCK)
        LEFT JOIN ClinicalGeniusEhr.dbo.PatientVisits pvt
            ON pvt.PatientVisitUniqueId = pyc.PatientVisit
        LEFT JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy
            ON ppy.PatientPayerGuid = pyc.PayerGuid
        LEFT JOIN ClinicalGeniusEhr.dbo.InsurancePlans ip
            ON ip.PlanGuid = ppy.PlanGuid
        LEFT JOIN ClinicalGeniusEhr.dbo.Payers pyr
            ON pyr.PayerGuid = ip.PayerGuid
        WHERE pyc.ClaimGuid = @ClaimGuid
          AND pyc.FacilityId = @FacilityId;

        IF @@ROWCOUNT = 0
            THROW 50003, N'Validation Failure: ClaimGuid was not found for the specified FacilityId.', 1;

        IF @PatientVisit IS NOT NULL AND @ClaimVisitId IS NOT NULL AND @ClaimVisitId <> @PatientVisit
            THROW 50004, N'Validation Failure: @PatientVisit does not match the visit linked to @ClaimGuid.', 1;

        SET @EffectiveVisit = COALESCE(@PatientVisit, @ClaimVisitId);

        IF @PatientId IS NULL AND @EffectiveVisit IS NOT NULL
        BEGIN
            SELECT TOP (1) @PatientId = pvt.PatientId
            FROM ClinicalGeniusEhr.dbo.PatientVisits pvt
            WHERE pvt.PatientVisitUniqueId = @EffectiveVisit;
        END

        IF @PatientId IS NULL
            THROW 50005, N'Validation Failure: Unable to resolve PatientId for the target claim/visit.', 1;

        SET @PayerId = ISNULL(@PayerId, N'999999999');

        -- 2. Lock and stamp eligible unbatched active transactions
        UPDATE [dbo].[PatientTransactions] WITH (UPDLOCK, ROWLOCK)
        SET
            DIANInvoiceBatchId = @InvoiceGuid,
            CurrentWorkflowStatus = N'Batched for DIAN'
        OUTPUT
            INSERTED.Facility,
            INSERTED.TransactionGuid,
            INSERTED.TransactionType,
            INSERTED.CupsCode,
            INSERTED.SurgicalComponent,
            INSERTED.TransactionQuantity,
            INSERTED.PerItemChargeAmount,
            INSERTED.TaxRate,
            INSERTED.NetAmount,
            INSERTED.DiscountAmount,
            INSERTED.TaxAmount,
            INSERTED.DispensingValue,
            INSERTED.DateTimeEntered
        INTO @LockedTransactions
        WHERE ClaimGuid = @ClaimGuid
          AND Status = N'Active'
          AND Facility = @FacilityId
          AND ISNULL(NetAmount, 0) > 0
          AND DIANInvoiceBatchId IS NULL
          AND (
              ISNULL(TransactionType, N'') <> N'Honorary'
              OR (TransactionType = N'Honorary' AND CurrentWorkflowStatus = N'Approved')
          );

        IF NOT EXISTS (SELECT 1 FROM @LockedTransactions)
            THROW 50006, N'Validation Failure: No eligible unbatched active transactions were found for this claim.', 1;

        -- 3. Compute cent-exact line pillars (NetAmount is already inclusive of DispensingValue)
        ;WITH BaseCalc AS (
            SELECT
                pt.Facility,
                ROW_NUMBER() OVER (ORDER BY pt.DateTimeEntered ASC, pt.TransactionGuid ASC) AS LineNumber,
                pt.TransactionGuid,
                pt.TransactionType,
                pt.CupsCode,
                pt.SurgicalComponent,
                ISNULL(pt.TransactionQuantity, 0.0000) AS Quantity,
                pt.TaxRate,
                -- Strip embedded TaxAmount only on fee-audited rows; otherwise use inclusive NetAmount directly
                ROUND(
                    CASE
                        WHEN ISNULL(pt.TaxAmount, 0) > 0
                             AND ISNULL(pt.PerItemChargeAmount, 0) > 0
                             AND ABS(
                                 pt.NetAmount - (
                                     ROUND(ISNULL(pt.TransactionQuantity, 0) * pt.PerItemChargeAmount, 2)
                                     - ISNULL(pt.DiscountAmount, 0)
                                     + pt.TaxAmount
                                 )
                             ) <= 0.05
                        THEN ROUND(ISNULL(pt.TransactionQuantity, 0) * pt.PerItemChargeAmount, 2) + ISNULL(pt.DispensingValue, 0.00)
                        ELSE ISNULL(pt.NetAmount, 0.00)
                    END,
                    2
                ) AS LineGrossAmount,
                ROUND(ISNULL(pt.DiscountAmount, 0.00), 2) AS LineDiscountAmount,
                ROUND(ISNULL(pt.TaxAmount, 0.00), 2) AS LineTaxAmount
            FROM @LockedTransactions pt
        )
        INSERT INTO @CalculatedLines (
            Facility, LineNumber, TransactionGuid, LineType, ItemCode, ItemDescription,
            Quantity, UnitOfMeasure, UnitPrice, LineGrossAmount, LineDiscountAmount,
            LineTaxableAmount, LineTaxPercentage, LineTaxAmount, LineNetAmount
        )
        SELECT
            bc.Facility,
            bc.LineNumber,
            bc.TransactionGuid,
            bc.TransactionType,
            bc.CupsCode,
            bc.SurgicalComponent,
            bc.Quantity,
            '94' AS UnitOfMeasure,
            CASE
                WHEN bc.Quantity > 0 THEN ROUND(bc.LineGrossAmount / bc.Quantity, 4)
                ELSE bc.LineGrossAmount
            END AS UnitPrice,
            bc.LineGrossAmount,
            bc.LineDiscountAmount,
            CASE
                WHEN bc.LineTaxAmount > 0.00 THEN ROUND(bc.LineGrossAmount - bc.LineDiscountAmount, 2)
                ELSE 0.00
            END AS LineTaxableAmount,
            CASE
                WHEN bc.LineTaxAmount <= 0.00 THEN 0.00
                WHEN ISNULL(bc.TaxRate, 0) > 0 AND bc.TaxRate <= 1 THEN ROUND(bc.TaxRate * 100.0, 2)
                WHEN ISNULL(bc.TaxRate, 0) > 1 THEN ROUND(bc.TaxRate, 2)
                WHEN (bc.LineGrossAmount - bc.LineDiscountAmount) > 0.00
                THEN ROUND((bc.LineTaxAmount / (bc.LineGrossAmount - bc.LineDiscountAmount)) * 100.0, 2)
                ELSE 19.00
            END AS LineTaxPercentage,
            bc.LineTaxAmount,
            ROUND((bc.LineGrossAmount - bc.LineDiscountAmount) + bc.LineTaxAmount, 2) AS LineNetAmount
        FROM BaseCalc bc;

        -- 4. Aggregate header pillars directly from rounded lines
        SELECT
            @GrossAmount = ISNULL(SUM(LineGrossAmount), 0.00),
            @DiscountAmount = ISNULL(SUM(LineDiscountAmount), 0.00),
            @TaxableAmount = ISNULL(SUM(LineTaxableAmount), 0.00),
            @TaxAmount = ISNULL(SUM(LineTaxAmount), 0.00)
        FROM @CalculatedLines;

        SET @NetAmount = (@GrossAmount - @DiscountAmount + @TaxAmount) - @CopayOrCuotaAmount;

        IF @NetAmount < 0.00
            THROW 50007, N'Validation Failure: Claim copay/coinsurance exceeds total billable invoice charges.', 1;

        -- 5. Generate consecutive DIAN invoice number per Facility + Prefix
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = N'Exclusive',
            @LockOwner = N'Transaction',
            @LockTimeout = 15000;

        IF @LockResult < 0
            THROW 50008, N'Timeout acquiring sequence lock for DIAN invoice numbering.', 1;

        SELECT @CurrentMaxId = ISNULL(
            MAX(TRY_CAST(SUBSTRING(InvoiceNumber, LEN(@InvoicePrefix) + 1, 20) AS BIGINT)),
            100000
        )
        FROM [dbo].[DianInvoices] WITH (UPDLOCK, HOLDLOCK)
        WHERE FacilityId = @FacilityId
          AND InvoiceNumber LIKE @InvoicePrefix + N'%'
          AND LEN(InvoiceNumber) > LEN(@InvoicePrefix)
          AND SUBSTRING(InvoiceNumber, LEN(@InvoicePrefix) + 1, 20) NOT LIKE N'%[^0-9]%';

        SET @InvoiceNumber = @InvoicePrefix + CAST(@CurrentMaxId + 1 AS NVARCHAR(15));

        -- 6. Insert DIAN Invoice Header
        INSERT INTO [dbo].[DianInvoices] (
            FacilityId, InvoiceGuid, InvoicePrefix, InvoiceNumber, ResolutionNumber, PatientVisit,
            ClaimGuid, PatientId, PayerId, IssueDateTime, DueDate,
            OperationType, InvoiceType, GrossAmount, DiscountAmount, TaxableAmount,
            TaxAmount, CopayOrCuotaAmount, NetAmount, CUFE, CUDE, DianStatus,
            DateTimeEntered, LastUpdatedBy
        )
        VALUES (
            @FacilityId, @InvoiceGuid, @InvoicePrefix, @InvoiceNumber, @ResolutionNumber, @EffectiveVisit,
            @ClaimGuid, @PatientId, @PayerId, @IssueDateTime, @DueDate,
            '10', '01', @GrossAmount, @DiscountAmount, @TaxableAmount,
            @TaxAmount, @CopayOrCuotaAmount, @NetAmount, NULL, NULL, N'Draft',
            SYSDATETIME(), @UserId
        );

        -- 7. Insert DIAN Invoice Lines
        INSERT INTO [dbo].[DianInvoiceLines] (
            FacilityId, InvoiceGuid, LineNumber, TransactionGuid, LineType,
            ItemCode, ItemDescription, Quantity, UnitOfMeasure,
            UnitPrice, LineGrossAmount, LineDiscountAmount, LineTaxableAmount,
            LineTaxPercentage, LineTaxAmount, LineNetAmount
        )
        SELECT
            cl.Facility,
            @InvoiceGuid,
            cl.LineNumber,
            cl.TransactionGuid,
            cl.LineType,
            cl.ItemCode,
            cl.ItemDescription,
            cl.Quantity,
            cl.UnitOfMeasure,
            cl.UnitPrice,
            cl.LineGrossAmount,
            cl.LineDiscountAmount,
            cl.LineTaxableAmount,
            cl.LineTaxPercentage,
            cl.LineTaxAmount,
            cl.LineNetAmount
        FROM @CalculatedLines cl
        ORDER BY cl.LineNumber ASC;

        IF @TranCount = 0
            COMMIT TRANSACTION;

        SELECT
            @InvoiceGuid AS InvoiceGuid,
            @InvoiceNumber AS InvoiceNumber;
    END TRY
    BEGIN CATCH
        IF @TranCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @TranCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_COLCreateDIANInvoice;

        THROW;
    END CATCH
END;
GO