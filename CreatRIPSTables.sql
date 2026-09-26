-- ==========================================================================================
-- RIPS RESOLUCIÓN 2275 COMPLIANCE LEDGER SCHEMA
-- TARGET ARCHITECTURE: SQL Server Enterprise 2014
-- ==========================================================================================

-- 1. HEADER LEDGER: RipsTransactions
CREATE TABLE ClinicalGeniusSupplyChain.RipsTransactions (
    RipsGuid NVARCHAR(50) NOT NULL DEFAULT NEWID(),
    InvoiceGuid NVARCHAR(50) NOT NULL,          -- Direct link to your local DIAN Invoice ledger
    FacilityId NVARCHAR(50) NOT NULL,               -- Multi-tenant separation boundary
    NumFactura NVARCHAR(20) NOT NULL,               -- Mapped to DIAN InvoiceNumber
    TipoDocumentoPrestador VARCHAR(5) NOT NULL DEFAULT 'NI', -- NIT of your clinic
    NumDocumentoPrestador NVARCHAR(20) NOT NULL,    -- 900123456
    CodPrestador VARCHAR(12) NOT NULL,              -- Your clinic's official 12-digit REPS registry code
    TipoNota VARCHAR(5) NULL,                       -- NULL for invoice, 'NC'/'ND' for notes
    
    -- Summary Controls
    TotalUsuarios INT NOT NULL DEFAULT 1,
    DateTimeGenerated DATETIME NOT NULL DEFAULT GETDATE(),
    RipsStatus VARCHAR(20) NOT NULL DEFAULT 'Draft',-- Draft, Validated, Rejected, Sent
    
    CONSTRAINT PK_RipsTransactions PRIMARY KEY CLUSTERED (RipsGuid),
    CONSTRAINT FK_RipsTransactions_DianInvoices FOREIGN KEY (InvoiceGuid)
        REFERENCES ClinicalGeniusSupplyChain.DianInvoices (InvoiceGuid) ON DELETE CASCADE
);

-- 2. USER DETAILS LEDGER: RipsUsuarios (Replaces old US file metadata)
CREATE TABLE ClinicalGeniusSupplyChain.RipsUsuarios (
    RipsUserGuid NVARCHAR(50) NOT NULL DEFAULT NEWID(),
    RipsGuid NVARCHAR(50) NOT NULL,
    TipoIdentificacion VARCHAR(5) NOT NULL,         -- CC, TI, RC, CE, PA, NV...
    NumIdentificacion NVARCHAR(20) NOT NULL,
    TipoUsuario VARCHAR(5) NOT NULL,               -- '01' Contributivo, '02' Subsidiado, '05' Particular...
    FechaNacimiento DATE NOT NULL,
    CodSexo VARCHAR(2) NOT NULL,                   -- M, F
    CodPaisResidencia VARCHAR(5) NOT NULL DEFAULT '170', -- '170' for Colombia
    CodMunicipioResidencia VARCHAR(10) NOT NULL,    -- 5-digit DANE code (e.g., '11001' for Bogotá)
    ZonaTerritorioResidencia VARCHAR(2) NOT NULL,   -- 'U' Urbana, 'R' Rural
    
    CONSTRAINT PK_RipsUsuarios PRIMARY KEY CLUSTERED (RipsUserGuid),
    CONSTRAINT FK_RipsUsuarios_RipsTransactions FOREIGN KEY (RipsGuid)
        REFERENCES ClinicalGeniusSupplyChain.RipsTransactions (RipsGuid) ON DELETE CASCADE
);

-- 3. MEDICAL SERVICES INDEPENDENT LEDGER: RipsServicios (Consolidates old AC, AP, AM files into unified fields)
CREATE TABLE ClinicalGeniusSupplyChain.RipsServicios (
    RipsServiceGuid NVARCHAR(50) NOT NULL DEFAULT NEWID(),
    RipsGuid NVARCHAR(50) NOT NULL,
    TransactionGuid NVARCHAR(50) NOT NULL,      -- Direct trace link back to PatientTransactions row
    ServiceCategory VARCHAR(15) NOT NULL,          -- 'Consultas', 'Procedimientos', 'Medicamentos'
    
    -- Unified RIPS Regulatory Columns (Resolución 2275 Fields)
    CodServicio NVARCHAR(20) NOT NULL,              -- CUPS code or CUM identifier string
    Cantidad DECIMAL(18,2) NOT NULL DEFAULT 1.00,
    ValorUnitario DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    ValorTotal DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    
    -- Specialized Medical Audit Context
    ConceptoRecaudo VARCHAR(5) NOT NULL DEFAULT '05',-- '05' for Net EPS payable, '01' Copago, '02' Cuota Mod
    ValorCuota DECIMAL(18,2) NOT NULL DEFAULT 0.00,  -- Copay or Coinsurance applied directly to this line
    FechaPrestacion DATETIME NOT NULL,
    
    -- Clinical Diagnostic Metadata
    DiagnosticoPrincipal VARCHAR(10) NULL,          -- ICD-10 Code (CIE-10 standard e.g., 'I10X')
    DiagnosticoRelacionado VARCHAR(10) NULL,
    FinalidadTecnologia VARCHAR(5) NOT NULL DEFAULT '44', -- '44' for Therapeutic, '01' for Diagnostic
    TipoDiagnostico VARCHAR(5) NULL,                -- '1' Impresión diag, '2' Confirmado nuevo, '3' Confirmado repetido
    
    -- Authorization Tracking
    NumAutorizacion NVARCHAR(30) NULL,
    
    CONSTRAINT PK_RipsServicios PRIMARY KEY CLUSTERED (RipsServiceGuid),
    CONSTRAINT FK_RipsServicios_RipsTransactions FOREIGN KEY (RipsGuid)
        REFERENCES ClinicalGeniusSupplyChain.RipsTransactions (RipsGuid) ON DELETE CASCADE
);

-- Optimization Indexing
CREATE NONCLUSTERED INDEX IX_RipsTransactions_Tenant 
    ON ClinicalGeniusSupplyChain.RipsTransactions (FacilityId, InvoiceGuid);
CREATE NONCLUSTERED INDEX IX_RipsServicios_RipsGuid 
    ON ClinicalGeniusSupplyChain.RipsServicios (RipsGuid);
GO
