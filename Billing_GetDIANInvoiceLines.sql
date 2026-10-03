USE [ClinicalGeniusSupplyChain]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [odata].[COLGetDianInvoiceLines]
    @InvoiceGuid NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        dil.InvoiceLineGuid,
        dil.InvoiceGuid,
        dil.LineNumber,
        dil.ItemCode,
        dil.ItemDescription,
        dil.Quantity,
        dil.UnitPrice,
        dil.TaxAmount,
        dil.LineNetAmount
    FROM ClinicalGeniusSupplyChain.DianInvoiceLines dil WITH(NOLOCK)
    WHERE dil.InvoiceGuid = @InvoiceGuid
    ORDER BY dil.LineNumber ASC;
END;
GO