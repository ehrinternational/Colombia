-- ==========================================================================================
-- DIAN ELECTRONIC INVOICING COMPLIANCE REGISTRY SCHEMA
-- TARGET ARCHITECTURE: SQL Server Enterprise 2014
-- SPECIFICATION: COLLOMBIAN DIAN RESOLUCIÓN 000165 NATIVE COMPLIANCE
-- ==========================================================================================

-- 1. HEADER LEDGER: DianInvoices
CREATE TABLE ClinicalGeniusSupplyChain.DianInvoices (
    FacilityId NVARCHAR(50),
    InvoiceGuid NVARCHAR(50) NOT NULL DEFAULT NEWID(),
    InvoiceNumber NVARCHAR(20) NOT NULL,            -- e.g., SETT12345 (Prefijo + Número Correlativo)
    ResolutionNumber NVARCHAR(50) NOT NULL,         -- Official DIAN Resolution Auth Token
    PatientVisit NVARCHAR(50) NOT NULL,             -- Core relation bridge back to your EHR
    ClaimGuid NVARCHAR(50) NULL,                    -- Core relation bridge back to PayerClaims
    PatientId NVARCHAR(50) NOT NULL,                -- Target Citizen ID / Passport
    PayerId NVARCHAR(50) NOT NULL,                  -- NIT of the EPS / Insurance Company
    IssueDateTime DATETIME NOT NULL,                -- Official timestamp bound to XML delivery
    DueDate DATETIME NOT NULL,                      -- Payment terms expiration date
    OperationType VARCHAR(5) NOT NULL DEFAULT '10',  -- DIAN code: '10' for Standard, '08' for Health Sector AIU
    InvoiceType VARCHAR(5) NOT NULL DEFAULT '01',   -- '01' Factura de Venta, '91' Nota Crédito, '92' Nota Débito
    
    -- Monetary Liquidation Pillars (Strict Numeric Alignment)
    GrossAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,  -- Total line-items before discounts/taxes
    DiscountAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,-- Total contractual discounts applied
    TaxableAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00, -- Base for IVA / IPU calculations
    TaxAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,     -- Total IVA collected
    CopayOrCuotaAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00, -- Copagos / Cuotas Moderadoras deducted
    NetAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,     -- Final Net Payables (Gross - Disc + Tax - Copay)
    
    -- Cryptographic & Regulatory Fields
    CUFE VARCHAR(100) NULL,                         -- Código Único de Facturación Electrónica (SHA-384 string)
    QrCodeUrl NVARCHAR(512) NULL,                   -- Mandatory string pointing to the DIAN valid public site
    DianStatus VARCHAR(30) NOT NULL DEFAULT 'Draft',-- Draft, Signed, Sent, Approved, Rejected
    DianResponseCode VARCHAR(10) NULL,
    DianResponseDescription NVARCHAR(MAX) NULL,
    
    -- Technical Audit Logging Fields
    DateTimeEntered DATETIME NOT NULL DEFAULT GETDATE(),
    LastUpdatedBy NVARCHAR(100) NOT NULL DEFAULT 'DianBillingEngine',
    DateTimeLastUpdated DATETIME NULL,
    
    CONSTRAINT PK_DianInvoices PRIMARY KEY CLUSTERED (InvoiceGuid),
    CONSTRAINT UQ_DianInvoice_Number UNIQUE (InvoiceNumber),
    CONSTRAINT FK_DianInvoices_PatientVisits FOREIGN KEY (PatientVisit) 
        REFERENCES ClinicalGeniusEhr.dbo.PatientVisits (PatientVisit) -- Adjust cross-db pointer naming if needed
);

-- 2. ITEMIZATION DETAIL LEDGER: DianInvoiceLines
CREATE TABLE ClinicalGeniusSupplyChain.DianInvoiceLines (
    FacilityId NVARCHAR(50),
    InvoiceLineGuid NVARCHAR(50) NOT NULL DEFAULT NEWID(),
    InvoiceGuid NVARCHAR(50) NOT NULL,
    LineNumber INT NOT NULL,                        -- Sequential row order index (1, 2, 3...)
    TransactionGuid NVARCHAR(50) NULL,          -- Reverse link to your PatientTransactions ledger
    LineType VARCHAR(15) NOT NULL,                  -- 'Surgery', 'Procedure', 'Medication'
    ItemCode NVARCHAR(50) NOT NULL,                 -- CUPS code or CUM string identifier
    ItemDescription NVARCHAR(250) NOT NULL,         -- Clear commercial item descriptor text
    Quantity DECIMAL(18,4) NOT NULL DEFAULT 1.0000, -- Scalar tracking metrics (Allows precise fractional doses)
    UnitOfMeasure VARCHAR(5) NOT NULL DEFAULT '94',  -- DIAN Code: '94' per activity, 'ZZ' per package, or CUM metrics
    
    -- Cost breakdowns per row
    UnitPrice DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    LineGrossAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    LineDiscountAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    LineTaxableAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    LineTaxPercentage DECIMAL(5,2) NOT NULL DEFAULT 0.00, -- e.g., 0.00 or 19.00 (Exento vs Gravado)
    LineTaxAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    LineNetAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    
    CONSTRAINT PK_DianInvoiceLines PRIMARY KEY CLUSTERED (InvoiceLineGuid),
    CONSTRAINT UQ_Invoice_Line_Seq UNIQUE (InvoiceGuid, LineNumber),
    CONSTRAINT FK_DianInvoiceLines_DianInvoices FOREIGN KEY (InvoiceGuid) 
        REFERENCES ClinicalGeniusSupplyChain.DianInvoices (InvoiceGuid) ON DELETE CASCADE
);

-- 3. TRANSIT TRANSACTION BLOB PAYLOAD RECORD: DianInvoiceTransmissions
CREATE TABLE ClinicalGeniusSupplyChain.DianInvoiceTransmissions (
    TransmissionGuid NVARCHAR(50) NOT NULL DEFAULT NEWID(),
    InvoiceGuid NVARCHAR(50) NOT NULL,
    TransmissionAttempt INT NOT NULL DEFAULT 1,
    SentDateTime DATETIME NOT NULL DEFAULT GETDATE(),
    RequestPayloadXml XML NOT NULL,                 -- RAW UBL 2.1 Compliant XML generated by your engine
    ResponsePayloadXml XML NULL,                    -- RAW XML document containing DIAN ApplicationResponse string
    TrackId VARCHAR(100) NULL,                      -- DIAN validation processing token (UUID format)
    IsSuccess BIT NOT NULL DEFAULT 0,
    
    CONSTRAINT PK_DianInvoiceTransmissions PRIMARY KEY CLUSTERED (TransmissionGuid),
    CONSTRAINT FK_DianInvoiceTransmissions_DianInvoices FOREIGN KEY (InvoiceGuid) 
        REFERENCES ClinicalGeniusSupplyChain.DianInvoices (InvoiceGuid) ON DELETE CASCADE
);

-- CREATE INDICES FOR PEAK RE-LIQUIDATION AND AUDITING OVERHEAD SPEEDS ON MASSIVE DATASETS
CREATE NONCLUSTERED INDEX IX_DianInvoices_PatientVisit 
    ON ClinicalGeniusSupplyChain.DianInvoices (PatientVisit);

CREATE NONCLUSTERED INDEX IX_DianInvoices_CUFE 
    ON ClinicalGeniusSupplyChain.DianInvoices (CUFE) 
    WHERE CUFE IS NOT NULL;

CREATE NONCLUSTERED INDEX IX_DianInvoiceLines_InvoiceGuid 
    ON ClinicalGeniusSupplyChain.DianInvoiceLines (InvoiceGuid);
GO
