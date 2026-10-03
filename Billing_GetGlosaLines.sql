USE [ClinicalGeniusSupplyChain]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [odata].[COLGetGlosaLines]
    @GlosaGuid NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        gl.GlosaLineGuid,
        gl.InvoiceLineGuid,
        dil.LineNumber AS DianLineNumber,
        dil.ItemCode AS CupsCode,
        dil.ItemDescription,
        dil.Quantity,
        dil.UnitPrice,
        dil.LineNetAmount AS OriginalLineAmount,
        gl.GeneralGlosaCode,
        gl.SpecificGlosaCode,
        c.Description AS GlosaCodeDescription,
        gl.DisputedAmount,
        gl.AcceptedAmount,
        gl.DefendedAmount,
        gl.PayerObservation,
        gl.IpsAuditResponse,
        gl.LineStatus,
        pt.ProfessionalId, -- Enables tracing the dispute back to the specific physician
        pt.ProfessionalType
    FROM ClinicalGeniusSupplyChain.InvoiceGlosaLines gl WITH(NOLOCK)
    INNER JOIN ClinicalGeniusSupplyChain.DianInvoiceLines dil WITH(NOLOCK) 
        ON dil.InvoiceLineGuid = gl.InvoiceLineGuid
    INNER JOIN ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK) 
        ON pt.TransactionGuid = gl.TransactionGuid
    LEFT JOIN ClinicalGeniusSupplyChain.Catalog_GlosaCodes c WITH(NOLOCK) 
        ON c.GeneralCode = gl.GeneralGlosaCode AND c.SpecificCode = gl.SpecificGlosaCode
    WHERE gl.GlosaGuid = @GlosaGuid
    ORDER BY dil.LineNumber ASC;
END;
GO