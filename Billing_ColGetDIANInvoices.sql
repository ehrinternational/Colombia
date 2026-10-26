USE [ClinicalGeniusSupplyChain]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[COLGetDIANInvoices]
    @FacilityId NVARCHAR(50) = NULL,
    @InvoiceGuid NVARCHAR(50) = NULL, 
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
        -- Expose the InvoiceGuid as the DIANInvoiceBatchId to match the PatientTransactions schema
        -- This allows the UI administrative grids to easily link to the generated payload
        inv.InvoiceGuid AS DIANInvoiceBatchId,
        inv.FacilityId,
        inv.IssueDateTime,
        inv.DueDate,
        inv.InvoiceNumber,
        inv.InvoiceType,
        CASE inv.InvoiceType 
            WHEN '01' THEN 'Factura de Venta'
            WHEN '91' THEN 'Nota Crédito'
            WHEN '92' THEN 'Nota Débito'
            ELSE 'Otro'
        END AS InvoiceTypeDescription,
        inv.OperationType,
        inv.DianStatus,
        inv.PayerId,
        pyr.PayerName,
        inv.PatientId,
        pat.PatientFullName,
        inv.CUFE,
        inv.ResolutionNumber,
        -- Adjustment Note References
        inv.ReferencedInvoiceNumber,
        inv.ReferencedCUFE,
        -- Full UBL 2.1 Financial Pillars
        inv.GrossAmount,
        inv.DiscountAmount,
        inv.TaxableAmount,
        inv.TaxAmount,
        inv.CopayOrCuotaAmount,
        inv.NetAmount,
        inv.DianResponseDescription
    FROM ClinicalGeniusSupplyChain.dbo.DianInvoices inv WITH(NOLOCK)
    -- Point directly to the EHR database where the NITs were originally sourced
    LEFT JOIN ClinicalGeniusEhr.dbo.Payers pyr WITH(NOLOCK)
        ON ISNULL(pyr.NIT, pyr.PayerId) = inv.PayerId
    OUTER APPLY (
        -- Cleaned up potential double-spacing if middle name is null
        SELECT LTRIM(RTRIM(
            REPLACE(
                ISNULL(p.PatientFirstName, '') + ' ' + 
                ISNULL(p.PatientMiddleName + ' ', '') + 
                ISNULL(p.PatientLastName, ''), 
                '  ', ' '
            )
        )) AS PatientFullName
        FROM ClinicalGeniusEhr.dbo.PatientTable p WITH(NOLOCK)
        WHERE p.RecordUniqueId = inv.PatientId
    ) pat
    WHERE (@FacilityId IS NULL OR inv.FacilityId = @FacilityId)
      AND (@InvoiceGuid IS NULL OR inv.InvoiceGuid = @InvoiceGuid) 
      AND (@StartDate IS NULL OR inv.IssueDateTime >= @StartDate)
      AND (@EndDate IS NULL OR inv.IssueDateTime < DATEADD(DAY, 1, @EndDate))
      AND (@InvoiceType IS NULL OR inv.InvoiceType = @InvoiceType)
      AND (@InvoiceNumber IS NULL OR inv.InvoiceNumber = @InvoiceNumber)
      AND (@PayerId IS NULL OR inv.PayerId = @PayerId)
      AND (@PatientId IS NULL OR inv.PatientId = @PatientId)
    OPTION (RECOMPILE);
END;
GO