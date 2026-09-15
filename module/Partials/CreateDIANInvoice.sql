ALTER PROCEDURE ClinicalGeniusSupplyChain.usp_CreateDianInvoice
    @PatientVisit NVARCHAR(50),
    @FacilityId NVARCHAR(50),                     -- Explicit tenant partition filter
    @ClaimGuid NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Clean up optional parameter padding
    SET @ClaimGuid = NULLIF(TRIM(@ClaimGuid), '');

    -- Initialize tracking state variables
    DECLARE @PatientId NVARCHAR(50),
            @PayerId NVARCHAR(50),
            @NextInvoiceNumber NVARCHAR(20),
            @CurrentMaxId INT,
            @InvoicePrefix NVARCHAR(5),
            @ResolutionNumber NVARCHAR(50),
            @ClaimCopay DECIMAL(18,2) = 0.00,
            @ClaimCoinsurance DECIMAL(18,2) = 0.00;

    -- 1. Extract metadata from the core patient tracking context within tenant boundaries
    SELECT TOP 1 
        @PatientId = pv.PatientId
    FROM ClinicalGeniusEhr.dbo.PatientVisits pv WITH(NOLOCK)
    WHERE pv.PatientVisit = @PatientVisit
      AND pv.Facility = @FacilityId; -- Enforces strict tenant separation at the visit level

    -- Safeguard check: Abort if the visit does not exist for this tenant
    IF @PatientId IS NULL
    BEGIN
        RAISERROR('Validation Failure: Target PatientVisit does not exist for this Facility / Tenant.', 16, 1);
        RETURN;
    END;

    -- FIXED: Resolve PayerId directly from the ClaimGuid if present to prevent cross-year mapping mismatches
    IF @ClaimGuid IS NOT NULL
    BEGIN
        SELECT TOP 1 @PayerId = clm.PayerGuid -- Assuming PayerGuid exists on PayerClaims ledger
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims clm WITH(NOLOCK)
        WHERE clm.ClaimGuid = @ClaimGuid;
    END;

    -- Fallback strategy if ClaimGuid is empty or unresolved
    IF @PayerId IS NULL
    BEGIN
        SELECT TOP 1
            @PayerId = ISNULL(isc.PayerGuid, '222222222222') 
        FROM ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK)
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
            ON isc.ContractGuid = ppy.ContractGuid
        WHERE ppy.PatientPayerGuid = (
            SELECT TOP 1 PatientPayerGuid 
            FROM ClinicalGeniusEhr.dbo.PatientPayers WITH(NOLOCK) 
            WHERE PatientVisit = @PatientVisit 
            ORDER BY Ordinal ASC
        );
    END;

    SET @PayerId = ISNULL(@PayerId, '222222222222');

    -- DYNAMIC PREFIX CONFIGURATION RULE:
    -- Differentiates FE (Factura Electrónica for EPS) vs FP (Factura Particular for Self-Pay)
    IF @ClaimGuid IS NOT NULL
    BEGIN
        SET @InvoicePrefix = 'FE';
        SET @ResolutionNumber = '187640000001'; -- Target EPS Resolution placeholder authorized by DIAN
        
        -- Pull Cuota (Copay) and Copago (Coinsurance) directly from PayerClaims
        SELECT TOP 1
            @ClaimCopay = ISNULL(pyc.Copay, 0.00),                 
            @ClaimCoinsurance = ISNULL(pyc.MedicalCoinsurance, 0.00) 
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
        WHERE pyc.ClaimGuid = @ClaimGuid;
    END
    ELSE
    BEGIN
        SET @InvoicePrefix = 'FP';
        SET @ResolutionNumber = '187640000002'; -- Target Particular/Self-Pay Resolution placeholder
    END;

    -- 2. Thread-safe sequential numbering generation block scoped strictly by FacilityId
    BEGIN TRAN;
    BEGIN TRY
        
        SELECT @CurrentMaxId = ISNULL(MAX(CAST(SUBSTRING(InvoiceNumber, 4, 16) AS INT)), 100000)
        FROM ClinicalGeniusSupplyChain.DianInvoices WITH(XLOCK, ROWLOCK)
        WHERE InvoiceNumber LIKE @InvoicePrefix + '%'
          AND FacilityId = @FacilityId; -- Scopes sequence calculation exclusively to this tenant
        
        SET @NextInvoiceNumber = @InvoicePrefix + CAST(@CurrentMaxId + 1 AS NVARCHAR(16));

        -- Memory block anchor to bridge statement scopes
        DECLARE @InsertedInvoice TABLE (InvoiceGuid UNIQUEIDENTIFIER);

        -- 3. Header insertion using pre-calculated metrics arrays
        INSERT INTO ClinicalGeniusSupplyChain.DianInvoices (
            InvoiceNumber, ResolutionNumber, FacilityId, PatientVisit, ClaimGuid, PatientId, PayerId, 
            IssueDateTime, DueDate, GrossAmount, DiscountAmount, TaxableAmount, TaxAmount, 
            CopayOrCuotaAmount, NetAmount, DianStatus, LastUpdatedBy
        )
        OUTPUT inserted.InvoiceGuid INTO @InsertedInvoice
        SELECT 
            @NextInvoiceNumber,
            @ResolutionNumber, 
            @FacilityId, 
            @PatientVisit,
            @ClaimGuid,
            @PatientId,
            @PayerId,
            GETDATE(),
            DATEADD(day, 30, GETDATE()), 
            ISNULL(SUM(pt.NetAmount), 0.00) AS GrossAmount,
            ISNULL(SUM(pt.DiscountAmount), 0.00) AS DiscountAmount,
            ISNULL(SUM(pt.NetAmount - pt.DiscountAmount), 0.00) AS TaxableAmount,
            ISNULL(SUM(pt.TaxAmount), 0.00) AS TaxAmount,
            CAST((@ClaimCopay + @ClaimCoinsurance) AS DECIMAL(18,2)) AS CopayOrCuotaAmount, 
            ISNULL(SUM(pt.NetAmount - pt.DiscountAmount + pt.TaxAmount), 0.00) - CAST((@ClaimCopay + @ClaimCoinsurance) AS DECIMAL(18,2)) AS NetAmount,
            'Draft', 
            'DianBillingEngine'
        FROM ClinicalGeniusSupplyChain.PatientTransactions pt WITH(NOLOCK)
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Status = 'Active'
          AND pt.Facility = @FacilityId 
          AND (
                (@ClaimGuid IS NULL AND pt.ClaimGuid IS NULL) OR 
                (@ClaimGuid IS NOT NULL AND pt.ClaimGuid = @ClaimGuid)
              );

        DECLARE @NewInvoiceGuid UNIQUEIDENTIFIER;
        SELECT TOP 1 @NewInvoiceGuid = InvoiceGuid FROM @InsertedInvoice;

        -- 4. Line Item structural decomposition serialization pass
        INSERT INTO ClinicalGeniusSupplyChain.DianInvoiceLines (
            InvoiceGuid, LineNumber, TransactionGuid, LineType, ItemCode, 
            ItemDescription, Quantity, UnitOfMeasure, UnitPrice, LineGrossAmount, 
            LineDiscountAmount, LineTaxableAmount, LineTaxPercentage, LineTaxAmount, LineNetAmount
        )
        SELECT 
            @NewInvoiceGuid,
            ROW_NUMBER() OVER(ORDER BY pt.ExternalProcessedDateTime ASC, pt.CupsCode ASC),
            pt.TransactionGuid, 
            pt.TransactionType,
            CASE WHEN pt.TransactionType = 'Medication' THEN pt.CUMCode ELSE pt.CupsCode END AS ItemCode,
            
            -- FIXED: Added fallback mapping case statement to prevent null description errors on standalone procedures
            CASE 
                WHEN pt.TransactionType = 'BundleMaster' THEN 'Paquete Integral Quirúrgico: ' + ISNULL(pt.SurgicalComponent, 'Servicio Agrupado')
                ELSE ISNULL(pt.SurgicalComponent, 'Procedimiento / Servicio Clínico') 
            END AS ItemDescription,
            
            pt.Quantity,
            CASE WHEN pt.TransactionType = 'Medication' THEN '01' ELSE '94' END AS UnitOfMeasure, 
            pt.BaseUnitValue,
            pt.NetAmount AS LineGrossAmount,
            pt.DiscountAmount AS LineDiscountAmount,
            (pt.NetAmount - pt.DiscountAmount) AS LineTaxableAmount,
            0.00 AS LineTaxPercentage, 
            pt.TaxAmount AS LineTaxAmount,
            (pt.NetAmount - pt.DiscountAmount + pt.TaxAmount) AS LineNetAmount
        FROM ClinicalGeniusSupplyChain.PatientTransactions pt WITH(NOLOCK)
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Status = 'Active'
          AND pt.Facility = @FacilityId
          AND (
                (@ClaimGuid IS NULL AND pt.ClaimGuid IS NULL) OR 
                (@ClaimGuid IS NOT NULL AND pt.ClaimGuid = @ClaimGuid)
              );

        COMMIT TRAN;

        -- Return output metadata mapping tokens back out to your Node.js application layer orchestration
        SELECT @NewInvoiceGuid AS GeneratedInvoiceGuid, @NextInvoiceNumber AS GeneratedInvoiceNumber;

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
