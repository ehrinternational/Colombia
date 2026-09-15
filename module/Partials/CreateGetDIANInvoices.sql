ALTER PROCEDURE ClinicalGeniusSupplyChain.usp_GetDianInvoices
    @InvoiceGuid NVARCHAR(50) = NULL,
    @InvoiceNumber NVARCHAR(20) = NULL,
    @ResolutionNumber NVARCHAR(50) = NULL,
    @FacilityId NVARCHAR(50) = NULL, -- ADDED V2: Optional Facility filter constraint
    @PatientVisit NVARCHAR(50) = NULL,
    @ClaimGuid NVARCHAR(50) = NULL,
    @PatientId NVARCHAR(50) = NULL,
    @PayerId NVARCHAR(50) = NULL,
    @StartDate DATE = NULL,
    @EndDate DATE = NULL,
    @InvoiceType VARCHAR(5) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Initialize string query builders and clean parameter trailing padding gaps
    DECLARE @DynamicSQL NVARCHAR(MAX);
    DECLARE @WhereClauses NVARCHAR(MAX) = N'';

    SET @InvoiceNumber    = NULLIF(TRIM(@InvoiceNumber), '');
    SET @ResolutionNumber = NULLIF(TRIM(@ResolutionNumber), '');
    SET @FacilityId       = NULLIF(TRIM(@FacilityId), ''); -- Cleans inputs
    SET @PatientVisit     = NULLIF(TRIM(@PatientVisit), '');
    SET @ClaimGuid        = NULLIF(TRIM(@ClaimGuid), '');
    SET @PatientId        = NULLIF(TRIM(@PatientId), '');
    SET @PayerId          = NULLIF(TRIM(@PayerId), '');
    SET @InvoiceType      = NULLIF(TRIM(@InvoiceType), '');

    -- 2. Construct the core immutable projection block mapping the new V2 column
    SET @DynamicSQL = N'
        SELECT 
            inv.InvoiceGuid, inv.InvoiceNumber, inv.ResolutionNumber, inv.FacilityId, -- Projected out cleanly
            inv.PatientVisit, inv.ClaimGuid, inv.PatientId, inv.PayerId, inv.IssueDateTime, inv.DueDate,
            inv.OperationType, inv.InvoiceType,
            CASE 
                WHEN inv.InvoiceType = ''01'' THEN ''Factura de Venta''
                WHEN inv.InvoiceType = ''91'' THEN ''Nota Crédito''
                WHEN inv.InvoiceType = ''92'' THEN ''Nota Débito''
                ELSE ''Desconocido''
            END AS InvoiceTypeDescription,
            inv.GrossAmount, inv.DiscountAmount, inv.TaxableAmount, inv.TaxAmount,
            inv.CopayOrCuotaAmount, inv.NetAmount, inv.CUFE, inv.QrCodeUrl,
            inv.DianStatus, inv.DianResponseCode, inv.DianResponseDescription,
            inv.DateTimeEntered, inv.LastUpdatedBy
        FROM ClinicalGeniusSupplyChain.DianInvoices inv WITH(NOLOCK)
        WHERE 1 = 1'; 

    -- 3. Dynamically evaluate and append text constraints ONLY for active search dimensions
    IF @InvoiceGuid IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND inv.InvoiceGuid = @pInvoiceGuid';

    IF @InvoiceNumber IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND inv.InvoiceNumber = @pInvoiceNumber';

    IF @ResolutionNumber IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND inv.ResolutionNumber = @pResolutionNumber';

    IF @FacilityId IS NOT NULL -- ADDED CONSTRAINT ATTACHMENT
        SET @WhereClauses = @WhereClauses + N' AND inv.FacilityId = @pFacilityId';

    IF @PatientVisit IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND inv.PatientVisit = @pPatientVisit';

    IF @ClaimGuid IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND inv.ClaimGuid = @pClaimGuid';

    IF @PatientId IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND inv.PatientId = @pPatientId';

    IF @PayerId IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND inv.PayerId = @pPayerId';

    IF @InvoiceType IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND inv.InvoiceType = @pInvoiceType';

    IF @StartDate IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND CAST(inv.IssueDateTime AS DATE) >= @pStartDate';

    IF @EndDate IS NOT NULL
        SET @WhereClauses = @WhereClauses + N' AND CAST(inv.IssueDateTime AS DATE) <= @pEndDate';

    -- Combine the execution statement fragments cleanly
    SET @DynamicSQL = @DynamicSQL + @WhereClauses + N' ORDER BY inv.IssueDateTime DESC, inv.InvoiceNumber DESC;';

    -- 4. Execute via parameterized sp_executesql boundary walls to prevent injection threats
    DECLARE @ParamDefinition NVARCHAR(MAX) = N'
        @pInvoiceGuid NVARCHAR(50),
        @pInvoiceNumber NVARCHAR(20),
        @pResolutionNumber NVARCHAR(50),
        @pFacilityId NVARCHAR(50),
        @pPatientVisit NVARCHAR(50),
        @pClaimGuid NVARCHAR(50),
        @pPatientId NVARCHAR(50),
        @pPayerId NVARCHAR(50),
        @pStartDate DATE,
        @pEndDate DATE,
        @pInvoiceType VARCHAR(5)';

    EXEC sp_executesql @DynamicSQL, @ParamDefinition,
        @pInvoiceGuid = @InvoiceGuid,
        @pInvoiceNumber = @InvoiceNumber,
        @pResolutionNumber = @ResolutionNumber,
        @pFacilityId = @FacilityId,
        @pPatientVisit = @PatientVisit,
        @pClaimGuid = @ClaimGuid,
        @pPatientId = @PatientId,
        @pPayerId = @PayerId,
        @pStartDate = @StartDate,
        @pEndDate = @EndDate,
        @pInvoiceType = @InvoiceType;
END;
GO
