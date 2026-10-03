CREATE OR ALTER PROCEDURE [odata].[COLGetDIANInvoices]
    @FacilityId NVARCHAR(50) = NULL,
    @InvoiceGuid NVARCHAR(50) = NULL, -- Added parameter
    @StartDate DATE = NULL,
    @EndDate DATE = NULL,
    @InvoiceType VARCHAR(2) = NULL,
    @InvoiceNumber NVARCHAR(20) = NULL,
    @PayerId NVARCHAR(50) = NULL,
    @PatientId NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        inv.InvoiceGuid,
        inv.IssueDateTime,
        inv.InvoiceNumber,
        inv.InvoiceType,
        CASE inv.InvoiceType 
            WHEN '01' THEN 'Factura de Venta'
            WHEN '91' THEN 'Nota Crédito'
            WHEN '92' THEN 'Nota Débito'
            ELSE 'Otro'
        END AS InvoiceTypeDescription,
        inv.DianStatus,
        inv.PayerId,
        pyr.PayerName,
        inv.PatientId,
        pat.PatientFullName,
        inv.CUFE,
        inv.NetAmount
    FROM ClinicalGeniusSupplyChain.DianInvoices inv WITH(NOLOCK)
    LEFT JOIN ClinicalGeniusEhr.dbo.PatientPayers pyr WITH(NOLOCK)
        ON pyr.NationalId = inv.PayerId
    OUTER APPLY (
        SELECT LTRIM(RTRIM(
            ISNULL(p.PatientFirstName, '') + ' ' + 
            ISNULL(p.PatientMiddleName, '') + ' ' + 
            ISNULL(p.PatientLastName, '')
        )) AS PatientFullName
        FROM ClinicalGeniusEhr.dbo.Patients p WITH(NOLOCK)
        WHERE p.PatientId = inv.PatientId
    ) pat
    WHERE (@FacilityId IS NULL OR inv.FacilityId = @FacilityId)
      AND (@InvoiceGuid IS NULL OR inv.InvoiceGuid = @InvoiceGuid) -- Added filter
      AND (@StartDate IS NULL OR inv.IssueDateTime >= @StartDate)
      AND (@EndDate IS NULL OR inv.IssueDateTime < DATEADD(DAY, 1, @EndDate))
      AND (@InvoiceType IS NULL OR inv.InvoiceType = @InvoiceType)
      AND (@InvoiceNumber IS NULL OR inv.InvoiceNumber = @InvoiceNumber)
      AND (@PayerId IS NULL OR inv.PayerId = @PayerId)
      AND (@PatientId IS NULL OR inv.PatientId = @PatientId)
    ORDER BY inv.IssueDateTime DESC;
END;
GO