-- ==========================================================================================
-- RIPS RESOLUCION 2275 & 948 (2026) COMPLIANCE LEDGER SCHEMA
-- TARGET ARCHITECTURE: SQL Server 2014+ / Azure SQL Database
-- ==========================================================================================

-- 1. HEADER LEDGER: RipsTransactions
CREATE TABLE dbo.RipsTransactions (
    RipsGuid NVARCHAR(50) NOT NULL CONSTRAINT DF_RipsTransactions_RipsGuid DEFAULT NEWID(),
    InvoiceGuid NVARCHAR(50) NULL,                  -- Link to dbo.DianInvoices (NULL-capable for RIPS sin factura 'RS')
    FacilityId NVARCHAR(50) NOT NULL,               -- Multi-tenant separation boundary
    NumFactura NVARCHAR(20) NULL,                   -- Mapped to DIAN InvoiceNumber (NULL when sin factura 'RS')
    TipoDocumentoPrestador VARCHAR(5) NOT NULL CONSTRAINT DF_RipsTransactions_TipoDoc DEFAULT 'NI',
    NumDocumentoPrestador NVARCHAR(20) NOT NULL,    -- NIT of clinic (e.g., 900123456)
    CodPrestador VARCHAR(12) NOT NULL,              -- Clinic's official 12-digit REPS registry code
    TipoNota VARCHAR(5) NULL,                       -- NULL for standard invoice, 'NC'/'ND'/'NA'/'RS' for notes/no-invoice
    NumNota NVARCHAR(20) NULL,                      -- Mandatory root note number when TipoNota IN ('NC', 'ND', 'NA')

    -- SIIFA / MUV Regulatory Validation & Contract Controls (Res. 948 de 2026)
    CUCON VARCHAR(64) NULL,                         -- Codigo Unico de Contrato (SHA-256 contract hash for EPS claims)
    CUV VARCHAR(128) NULL,                          -- Codigo Unico de Validacion issued by MinSalud MUV/SIIFA
    FechaValidacion DATETIMEOFFSET NULL,            -- Official MUV validation timestamp
    ValidationResponseJson NVARCHAR(MAX) NULL,      -- Raw MUV/SIIFA response & rejection diagnostics payload

    -- Summary Controls
    TotalUsuarios INT NOT NULL CONSTRAINT DF_RipsTransactions_TotalUsuarios DEFAULT 1,
    DateTimeGenerated DATETIME NOT NULL CONSTRAINT DF_RipsTransactions_DateTimeGenerated DEFAULT GETDATE(),
    RipsStatus VARCHAR(20) NOT NULL CONSTRAINT DF_RipsTransactions_RipsStatus DEFAULT 'Draft', -- Draft, Validated, Rejected, Sent

    CONSTRAINT PK_RipsTransactions PRIMARY KEY CLUSTERED (RipsGuid)
);
GO

-- 2. USER DETAILS LEDGER: RipsUsuarios (Replaces legacy US file metadata)
CREATE TABLE dbo.RipsUsuarios (
    RipsUserGuid NVARCHAR(50) NOT NULL CONSTRAINT DF_RipsUsuarios_RipsUserGuid DEFAULT NEWID(),
    RipsGuid NVARCHAR(50) NOT NULL,
    Consecutivo INT NOT NULL CONSTRAINT DF_RipsUsuarios_Consecutivo DEFAULT 1,
    TipoIdentificacion VARCHAR(5) NOT NULL,         -- CC, TI, RC, CE, PA, NV, PEP, PPT...
    NumIdentificacion NVARCHAR(20) NOT NULL,
    TipoUsuario VARCHAR(5) NOT NULL,                -- '01' Contributivo, '02' Subsidiado, '05' Particular, '10' SOAT...
    FechaNacimiento DATE NOT NULL,
    CodSexo VARCHAR(2) NOT NULL,                    -- M, F
    CodPaisResidencia VARCHAR(5) NOT NULL CONSTRAINT DF_RipsUsuarios_CodPaisRes DEFAULT '170', -- '170' Colombia
    CodPaisOrigen NVARCHAR(3) NULL,                 -- Country of origin ISO numeric code (3 characters)
    CodMunicipioResidencia VARCHAR(10) NOT NULL,    -- 5-digit DANE code (e.g., '11001' for Bogota)
    ZonaTerritorioResidencia VARCHAR(2) NOT NULL,   -- 'U' Urbana, 'R' Rural (or '01'/'02' per catalog mapping)
    Incapacidad VARCHAR(2) NOT NULL CONSTRAINT DF_RipsUsuarios_Incapacidad DEFAULT 'NO',
    RegistroSIRAS NVARCHAR(60) NULL,                -- Required when TipoUsuario = '10' (SOAT)

    CONSTRAINT PK_RipsUsuarios PRIMARY KEY CLUSTERED (RipsUserGuid)
);
GO

-- 3. MEDICAL SERVICES INDEPENDENT LEDGER: RipsServicios (Consolidates legacy AC, AP, AM, AT files)
CREATE TABLE dbo.RipsServicios (
    RipsServiceGuid NVARCHAR(50) NOT NULL CONSTRAINT DF_RipsServicios_RipsServiceGuid DEFAULT NEWID(),
    RipsGuid NVARCHAR(50) NOT NULL,
    RipsUserGuid NVARCHAR(50) NULL,                 -- Optional link to RipsUsuarios for multi-patient consolidated RIPS
    TransactionGuid NVARCHAR(50) NOT NULL,          -- Direct trace link back to PatientTransactions row
    ServiceCategory VARCHAR(30) NOT NULL,           -- 'Consultas', 'Procedimientos', 'Medicamentos', 'OtrosServicios', 'Hospitalizacion', 'Urgencias', 'RecienNacidos'

    -- Unified RIPS Regulatory Columns
    CodServicio NVARCHAR(20) NOT NULL,              -- CUPS code or IUM/CUM identifier string
    Cantidad DECIMAL(18,2) NOT NULL CONSTRAINT DF_RipsServicios_Cantidad DEFAULT 1.00,
    ValorUnitario DECIMAL(18,2) NOT NULL CONSTRAINT DF_RipsServicios_ValorUnitario DEFAULT 0.00,
    ValorTotal DECIMAL(18,2) NOT NULL CONSTRAINT DF_RipsServicios_ValorTotal DEFAULT 0.00,
    ValorDispensacion DECIMAL(18,2) NOT NULL CONSTRAINT DF_RipsServicios_ValorDispensacion DEFAULT 0.00,

    -- Specialized Medical Audit Context
    ConceptoRecaudo VARCHAR(5) NOT NULL CONSTRAINT DF_RipsServicios_ConceptoRecaudo DEFAULT '05', -- '05' No aplica / Net EPS, '01' Copago, '02' Cuota Mod
    ValorCuota DECIMAL(18,2) NOT NULL CONSTRAINT DF_RipsServicios_ValorCuota DEFAULT 0.00,
    FechaPrestacion DATETIME NOT NULL,

    -- Clinical Diagnostic Metadata (ICD-10 & ICD-11 Parallel Structure)
    DiagnosticoPrincipal VARCHAR(10) NULL,              -- ICD-10 Principal Code
    DiagnosticoPrincipalCIE11 NVARCHAR(256) NULL,       -- ICD-11 Principal Code
    NomDiagnosticoPrincipalCIE11 NVARCHAR(1000) NULL,   -- ICD-11 Principal Name

    DiagnosticoRelacionado VARCHAR(10) NULL,            -- ICD-10 Related Code
    DiagnosticoRelacionado1CIE11 NVARCHAR(256) NULL,    -- ICD-11 Related Code 1
    NomDiagnosticoRelacionado1CIE11 NVARCHAR(1000) NULL,-- ICD-11 Related Name 1

    Complicacion VARCHAR(10) NULL,                      -- ICD-10 Complication Code
    ComplicacionCIE11 NVARCHAR(256) NULL,               -- ICD-11 Complication Code
    NomComplicacionCIE11 NVARCHAR(1000) NULL,           -- ICD-11 Complication Name

    FinalidadTecnologia VARCHAR(5) NOT NULL CONSTRAINT DF_RipsServicios_Finalidad DEFAULT '44', -- '44' Terapeutica, '15' Diagnostico, etc.
    TipoDiagnostico VARCHAR(5) NULL,                    -- '01' Impresion diag, '02' Confirmado nuevo, '03' Confirmado repetido

    -- Authorization & System Tracking
    NumAutorizacion NVARCHAR(30) NULL,                  -- Legacy auth (omitted/null for non-applicable medications)
    CodigoVIDA NVARCHAR(256) NULL,                      -- IHCE healthcare interoperability code

    CONSTRAINT PK_RipsServicios PRIMARY KEY CLUSTERED (RipsServiceGuid)
);
GO

-- Optimization Indexing
CREATE NONCLUSTERED INDEX IX_RipsTransactions_Tenant
    ON dbo.RipsTransactions (FacilityId, InvoiceGuid);

CREATE NONCLUSTERED INDEX IX_RipsUsuarios_RipsGuid
    ON dbo.RipsUsuarios (RipsGuid);

CREATE NONCLUSTERED INDEX IX_RipsServicios_RipsGuid
    ON dbo.RipsServicios (RipsGuid);
GO
