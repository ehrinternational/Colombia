USE [ClinicalGeniusSupplyChain]
GO

-- ==========================================================================================
-- 1. CATALOG: OFFICIAL MINSALUD GLOSA CODES (Res. 2284 de 2023)
-- ==========================================================================================
CREATE TABLE ClinicalGeniusSupplyChain.Catalog_GlosaCodes (
    GeneralCode VARCHAR(2) NOT NULL,            -- e.g., 'FA' (Facturación), 'TA' (Tarifas), 'SO' (Soportes)
    SpecificCode VARCHAR(3) NOT NULL,           -- e.g., '01', '02'
    Description NVARCHAR(255) NOT NULL,         -- Official MinSalud description
    Active BIT NOT NULL DEFAULT 1,
    CONSTRAINT PK_CatalogGlosaCodes PRIMARY KEY CLUSTERED (GeneralCode, SpecificCode)
);

-- ==========================================================================================
-- 2. HEADER: GLOSA DISPUTE TRACKER
-- ==========================================================================================
CREATE TABLE ClinicalGeniusSupplyChain.InvoiceGlosas (
    FacilityId NVARCHAR(50) NOT NULL,
    GlosaGuid NVARCHAR(50) NOT NULL DEFAULT CAST(NEWID() AS NVARCHAR(50)),
    InvoiceGuid NVARCHAR(50) NOT NULL,          -- FK to DianInvoices
    PayerGlosaReference NVARCHAR(100) NOT NULL, -- The tracking number provided by the EPS
    
    RadicationDate DATE NOT NULL,               -- Date the glosa was officially received
    ResponseDeadlineDate DATE NOT NULL,         -- RadicationDate + 15 business days (Res. 2284)
    
    TotalDisputedAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    TotalAcceptedAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,  -- Amount IPS concedes (Requires Nota Crédito)
    TotalDefendedAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,  -- Amount IPS legally justifies
    
    Status VARCHAR(30) NOT NULL DEFAULT 'Radicada', -- 'Radicada', 'En_Auditoria', 'Respondida', 'Aceptada', 'Levantada', 'Conciliada'
    
    DateTimeEntered DATETIME NOT NULL DEFAULT GETDATE(),
    LastUpdatedBy NVARCHAR(100) NOT NULL,
    DateTimeLastUpdated DATETIME NULL,
    CONSTRAINT PK_InvoiceGlosas PRIMARY KEY CLUSTERED (GlosaGuid)
);

-- ==========================================================================================
-- 3. DETAIL: LINE-LEVEL FINANCIAL MAPPING
-- ==========================================================================================
CREATE TABLE ClinicalGeniusSupplyChain.InvoiceGlosaLines (
    GlosaLineGuid NVARCHAR(50) NOT NULL DEFAULT CAST(NEWID() AS NVARCHAR(50)),
    GlosaGuid NVARCHAR(50) NOT NULL,            -- FK to InvoiceGlosas
    InvoiceLineGuid NVARCHAR(50) NOT NULL,      -- FK to DianInvoiceLines (What the EPS sees)
    TransactionGuid NVARCHAR(50) NOT NULL,      -- FK to PatientTransactions (What your ledger sees)
    
    GeneralGlosaCode VARCHAR(2) NOT NULL,       -- Matches Catalog_GlosaCodes.GeneralCode
    SpecificGlosaCode VARCHAR(3) NOT NULL,      -- Matches Catalog_GlosaCodes.SpecificCode
    
    DisputedAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    AcceptedAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    DefendedAmount DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    
    PayerObservation NVARCHAR(MAX) NULL,        -- EPS medical auditor's justification
    IpsAuditResponse NVARCHAR(MAX) NULL,        -- Your medical auditor's defense
    LineStatus VARCHAR(30) NOT NULL DEFAULT 'Pending', -- 'Pending', 'Accepted', 'Defended'
    
    CONSTRAINT PK_InvoiceGlosaLines PRIMARY KEY CLUSTERED (GlosaLineGuid)
);

-- ==========================================================================================
-- 4. WORKFLOW: AUDIT RESPONSE & LIFECYCLE TRACKING
-- ==========================================================================================
CREATE TABLE ClinicalGeniusSupplyChain.InvoiceGlosaResponses (
    ResponseGuid NVARCHAR(50) NOT NULL DEFAULT CAST(NEWID() AS NVARCHAR(50)),
    GlosaGuid NVARCHAR(50) NOT NULL,            -- FK to InvoiceGlosas
    
    ActionType VARCHAR(50) NOT NULL,            -- 'Respuesta_IPS', 'Ratificacion_EPS', 'Levantamiento_EPS', 'Acta_Conciliacion'
    OficioNumber NVARCHAR(100) NULL,            -- Formal document tracking number
    ActionDate DATE NOT NULL,
    
    AttachedEvidenceUrl NVARCHAR(1000) NULL,    -- Link to cloud storage for clinical notes/RIPS submitted
    AdjustmentInvoiceGuid NVARCHAR(50) NULL,    -- FK to DianInvoices if a Nota Crédito (Type 91) was generated
    
    AuditNotes NVARCHAR(MAX) NULL,
    CreatedBy NVARCHAR(100) NOT NULL,
    DateTimeEntered DATETIME NOT NULL DEFAULT GETDATE(),
    
    CONSTRAINT PK_InvoiceGlosaResponses PRIMARY KEY CLUSTERED (ResponseGuid)
);

-- ==========================================================================================
-- PERFORMANCE INDICES
-- ==========================================================================================
CREATE NONCLUSTERED INDEX IX_InvoiceGlosas_InvoiceGuid ON ClinicalGeniusSupplyChain.InvoiceGlosas (InvoiceGuid);
CREATE NONCLUSTERED INDEX IX_InvoiceGlosas_Deadline ON ClinicalGeniusSupplyChain.InvoiceGlosas (ResponseDeadlineDate) INCLUDE (Status);
CREATE NONCLUSTERED INDEX IX_InvoiceGlosaLines_GlosaGuid ON ClinicalGeniusSupplyChain.InvoiceGlosaLines (GlosaGuid);
CREATE NONCLUSTERED INDEX IX_InvoiceGlosaLines_TransactionGuid ON ClinicalGeniusSupplyChain.InvoiceGlosaLines (TransactionGuid);
GO