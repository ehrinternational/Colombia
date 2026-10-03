USE [ClinicalGeniusSupplyChain]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [odata].[COLGetGlosas]
    @FacilityId NVARCHAR(50),
    @GlosaGuid NVARCHAR(50) = NULL,
    @InvoiceNumber NVARCHAR(20) = NULL,
    @Status VARCHAR(30) = NULL,
    @StartDate DATE = NULL,
    @EndDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        g.GlosaGuid,
        g.InvoiceGuid,
        pay.PayerName,
        inv.InvoiceNumber,
        inv.IssueDateTime AS InvoiceDate,
        inv.NetAmount AS InvoiceTotalAmount,
        g.PayerGlosaReference,
        g.RadicationDate,
        g.ResponseDeadlineDate,
        g.TotalDisputedAmount,
        g.TotalAcceptedAmount,
        g.TotalDefendedAmount,
        g.Status,
        g.DateTimeEntered,
        g.LastUpdatedBy,
        DATEDIFF(DAY, GETDATE(), g.ResponseDeadlineDate) AS DaysRemaining
    FROM ClinicalGeniusSupplyChain.InvoiceGlosas g WITH(NOLOCK)
    INNER JOIN ClinicalGeniusSupplyChain.DianInvoices inv WITH(NOLOCK) 
        ON inv.InvoiceGuid = g.InvoiceGuid
    INNER JOIN ClinicalGeniusSupplyChain.PayerClaims pyc WITH(NOLOCK) 
        ON pyc.ClaimGuid = inv.ClaimGuid
    INNER JOIN ClinicalGeniusSupplyChain.PatientPayers ppy WITH(NOLOCK) 
        ON ppy.PatientPayerGuid = pyc.PayerGuid
    INNER JOIN ClinicalGeniusSupplyChain.Payers pay WITH(NOLOCK) 
        ON pay.PayerGuid = ppy.PayerGuid
    WHERE g.FacilityId = @FacilityId
      AND g.Status = @Status
      AND (@GlosaGuid IS NULL OR g.GlosaGuid = @GlosaGuid)
      AND (@InvoiceNumber IS NULL OR inv.InvoiceNumber = @InvoiceNumber)
      AND (@StartDate IS NULL OR g.RadicationDate >= @StartDate)
      AND (@EndDate IS NULL OR g.RadicationDate <= @EndDate)
    ORDER BY g.ResponseDeadlineDate ASC;
END;
GO