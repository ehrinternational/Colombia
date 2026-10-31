-- ==========================================================================================
-- DIAN ELECTRONIC INVOICING COMPLIANCE REGISTRY SCHEMA
-- TARGET ARCHITECTURE: SQL Server 2014+ / Azure SQL Database
-- SPECIFICATION: COLOMBIAN DIAN RESOLUCION 000165 & UBL 2.1 NATIVE COMPLIANCE
-- ==========================================================================================

-- 1. HEADER LEDGER: DianInvoices
CREATE TABLE dbo.DianInvoices (
    FacilityId NVARCHAR(50) NULL,
    InvoiceGuid NVARCHAR(50) NOT NULL CONSTRAINT DF_DianInvoices_InvoiceGuid DEFAULT NEWID(),
    SourceInvoiceGuid NVARCHAR(50) NULL,
    ReferencedInvoiceNumber NVARCHAR(30) NULL,      -- Original invoice number for Credit/Debit Notes (COLCreateDianAdjustmentNote)
    ReferencedCUFE VARCHAR(100) NULL,               -- Original 96-char SHA-384 CUFE for Credit/Debit Notes
    ReferencedIssueDate DATE NULL,                  -- Optional original issue date for UBL 2.1 BillingReference
    ReasonCode INT NULL,
    ReasonDescription NVARCHAR(250) NULL,
    InvoicePrefix NVARCHAR(10) NULL,                -- e.g., SETT (Prefijo separado)
    InvoiceNumber NVARCHAR(20) NOT NULL,            -- e.g., 12345 (Numero correlativo sin prefijo ni digito de verificacion)
    ResolutionNumber NVARCHAR(50) NOT NULL,         -- Official DIAN Resolution Auth Token
    PatientVisit NVARCHAR(50) NOT NULL,             -- Core relation bridge back to EHR
    ClaimGuid NVARCHAR(50) NULL,                    -- Core relation bridge back to PayerClaims
    PatientId NVARCHAR(50) NOT NULL,                -- Target Citizen ID / Passport
    PayerId NVARCHAR(50) NOT NULL,                  -- NIT of the EPS / Insurance Company
    CUCON VARCHAR(64) NULL,                         -- Optional SIIFA / Health Sector contract hash reference
    IssueDateTime DATETIMEOFFSET NOT NULL,          -- Official timestamp bound to XML delivery (e.g., -05:00)
    DueDate DATETIME NOT NULL,                      -- Payment terms expiration date
    OperationType VARCHAR(5) NOT NULL CONSTRAINT DF_DianInvoices_OperationType DEFAULT '10', -- '10' Standard, '08' Health AIU, 'SS-CUFE' Health
    InvoiceType VARCHAR(5) NOT NULL CONSTRAINT DF_DianInvoices_InvoiceType DEFAULT '01',     -- '01' Factura, '91' Nota Credito, '92' Nota Debito

    -- Monetary Liquidation Pillars (Strict Numeric Alignment)
    GrossAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoices_GrossAmount DEFAULT 0.00,
    DiscountAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoices_DiscountAmount DEFAULT 0.00,
    TaxableAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoices_TaxableAmount DEFAULT 0.00,
    TaxAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoices_TaxAmount DEFAULT 0.00,
    CopayOrCuotaAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoices_CopayAmount DEFAULT 0.00,
    NetAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoices_NetAmount DEFAULT 0.00,

    -- Cryptographic & Regulatory Fields
    CUFE VARCHAR(100) NULL,                         -- Codigo Unico de Facturacion Electronica (SHA-384) for Invoices
    CUDE VARCHAR(100) NULL,                         -- Codigo Unico de Documento Electronico (SHA-384) for Credit/Debit Notes
    QrCodeUrl NVARCHAR(512) NULL,                   -- Mandatory URL pointing to the DIAN validation portal
    DianStatus VARCHAR(30) NOT NULL CONSTRAINT DF_DianInvoices_DianStatus DEFAULT 'Draft', -- Draft, Signed, Sent, Approved, Rejected
    DianResponseCode VARCHAR(10) NULL,
    DianResponseDescription NVARCHAR(MAX) NULL,

    -- Technical Audit Logging Fields
    DateTimeEntered DATETIME NOT NULL CONSTRAINT DF_DianInvoices_DateTimeEntered DEFAULT GETDATE(),
    LastUpdatedBy NVARCHAR(100) NOT NULL CONSTRAINT DF_DianInvoices_LastUpdatedBy DEFAULT 'DianBillingEngine',
    DateTimeLastUpdated DATETIME NULL,

    CONSTRAINT PK_DianInvoices PRIMARY KEY CLUSTERED (InvoiceGuid)
);
GO

-- 2. ITEMIZATION DETAIL LEDGER: DianInvoiceLines
CREATE TABLE dbo.DianInvoiceLines (
    FacilityId NVARCHAR(50) NULL,
    InvoiceLineGuid NVARCHAR(50) NOT NULL CONSTRAINT DF_DianInvoiceLines_InvoiceLineGuid DEFAULT NEWID(),
    InvoiceGuid NVARCHAR(50) NOT NULL,
    LineNumber INT NOT NULL,                        -- Sequential row order index (1, 2, 3...)
    TransactionGuid NVARCHAR(50) NULL,              -- Reverse link to PatientTransactions ledger
    LineType VARCHAR(30) NOT NULL,                  -- 'Surgery', 'Procedure', 'Medication', 'Hospitalization', etc.
    ItemCode NVARCHAR(50) NOT NULL,                 -- CUPS code or CUM string identifier
    ItemDescription NVARCHAR(250) NOT NULL,         -- Clear commercial item descriptor text
    Quantity DECIMAL(18,4) NOT NULL CONSTRAINT DF_DianInvoiceLines_Quantity DEFAULT 1.0000,
    UnitOfMeasure VARCHAR(5) NOT NULL CONSTRAINT DF_DianInvoiceLines_UOM DEFAULT '94',     -- DIAN Code: '94' activity, 'ZZ' package

    -- Cost breakdowns per row
    UnitPrice DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoiceLines_UnitPrice DEFAULT 0.00,
    LineGrossAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoiceLines_Gross DEFAULT 0.00,
    LineDiscountAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoiceLines_Discount DEFAULT 0.00,
    LineTaxableAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoiceLines_Taxable DEFAULT 0.00,
    LineTaxPercentage DECIMAL(5,2) NOT NULL CONSTRAINT DF_DianInvoiceLines_TaxPct DEFAULT 0.00,
    LineTaxAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoiceLines_TaxAmt DEFAULT 0.00,
    LineNetAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_DianInvoiceLines_Net DEFAULT 0.00,

    CONSTRAINT PK_DianInvoiceLines PRIMARY KEY CLUSTERED (InvoiceLineGuid)
);
GO

-- 3. TRANSIT TRANSACTION BLOB PAYLOAD RECORD: DianInvoiceTransmissions
CREATE TABLE dbo.DianInvoiceTransmissions (
    TransmissionGuid NVARCHAR(50) NOT NULL CONSTRAINT DF_DianInvoiceTransmissions_Guid DEFAULT NEWID(),
    InvoiceGuid NVARCHAR(50) NOT NULL,
    TransmissionAttempt INT NOT NULL CONSTRAINT DF_DianInvoiceTransmissions_Attempt DEFAULT 1,
    SentDateTime DATETIME NOT NULL CONSTRAINT DF_DianInvoiceTransmissions_Sent DEFAULT GETDATE(),
    RequestPayloadXml XML NOT NULL,                 -- RAW UBL 2.1 Compliant XML generated by billing engine
    ResponsePayloadXml XML NULL,                    -- RAW XML document containing DIAN ApplicationResponse
    TrackId VARCHAR(100) NULL,                      -- DIAN validation processing token (UUID format)
    IsSuccess BIT NOT NULL CONSTRAINT DF_DianInvoiceTransmissions_Success DEFAULT 0,

    CONSTRAINT PK_DianInvoiceTransmissions PRIMARY KEY CLUSTERED (TransmissionGuid)
);
GO

-- OPTIMIZATION INDICES FOR RE-LIQUIDATION, ADJUSTMENT LOOKUPS, AND AUDITING
CREATE NONCLUSTERED INDEX IX_DianInvoices_PatientVisit
    ON dbo.DianInvoices (PatientVisit);

CREATE NONCLUSTERED INDEX IX_DianInvoices_Facility_InvoiceNumber
    ON dbo.DianInvoices (FacilityId, InvoiceType, InvoicePrefix, InvoiceNumber);

CREATE NONCLUSTERED INDEX IX_DianInvoices_SourceInvoiceGuid
    ON dbo.DianInvoices (SourceInvoiceGuid)
    WHERE SourceInvoiceGuid IS NOT NULL;

CREATE NONCLUSTERED INDEX IX_DianInvoices_CUFE
    ON dbo.DianInvoices (CUFE)
    WHERE CUFE IS NOT NULL;

CREATE NONCLUSTERED INDEX IX_DianInvoices_CUDE
    ON dbo.DianInvoices (CUDE)
    WHERE CUDE IS NOT NULL;

CREATE NONCLUSTERED INDEX IX_DianInvoiceLines_InvoiceGuid
    ON dbo.DianInvoiceLines (InvoiceGuid);

CREATE NONCLUSTERED INDEX IX_DianInvoiceTransmissions_InvoiceGuid
    ON dbo.DianInvoiceTransmissions (InvoiceGuid);
GO
