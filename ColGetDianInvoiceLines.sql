SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'[dbo].[COLGetDianInvoiceLines]', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE [dbo].[COLGetDianInvoiceLines] AS BEGIN SET NOCOUNT ON; END');
GO

-- ==========================================================================================
-- Procedure: [dbo].[COLGetDianInvoiceLines]
-- Purpose: Retrieves ordered DIAN UBL 2.1 line items for an invoice, with optional
--          multi-tenant FacilityId isolation.
-- Target: SQL Server 2014+
-- ==========================================================================================
ALTER PROCEDURE [dbo].[COLGetDianInvoiceLines]
    @InvoiceGuid NVARCHAR(50),
    @FacilityId  NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @InvoiceGuid = LTRIM(RTRIM(@InvoiceGuid));
    SET @FacilityId = NULLIF(LTRIM(RTRIM(@FacilityId)), N'');

    SELECT
        dil.InvoiceLineGuid,
        dil.InvoiceGuid,
        dil.LineNumber,
        dil.LineType,
        dil.ItemCode,
        dil.ItemDescription,
        dil.Quantity,
        dil.UnitOfMeasure,
        dil.UnitPrice,
        dil.LineGrossAmount,
        dil.LineDiscountAmount,
        dil.LineTaxableAmount,
        dil.LineTaxPercentage,
        dil.LineTaxAmount,
        dil.LineNetAmount,
        dil.TransactionGuid,
        dil.FacilityId
    FROM [dbo].[DianInvoiceLines] dil
    WHERE dil.InvoiceGuid = @InvoiceGuid
      AND (@FacilityId IS NULL OR dil.FacilityId = @FacilityId)
    ORDER BY dil.LineNumber ASC, dil.InvoiceLineGuid ASC;
END;
GO