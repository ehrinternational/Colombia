-- ==========================================================================================
-- ACCIDENT & SOAT / ARL REGULATORY REGISTRY SCHEMA
-- TARGET ARCHITECTURE: SQL Server 2014+ / Azure SQL Database
-- ==========================================================================================

CREATE TABLE dbo.Accident (
    AccidentGuid NVARCHAR(50) NOT NULL CONSTRAINT DF_Accident_AccidentGuid DEFAULT NEWID(),
    PatientVisit NVARCHAR(50) NOT NULL, -- Referenced in appendinsert
    AccidentType INT NULL,              -- Derived from AdmissionType

    -- Accident General Info
    Description NVARCHAR(500) NULL,
    Arl BIT NULL,
    ArlNumber VARCHAR(20) NULL,
    FuratNumber VARCHAR(20) NULL,       -- ARL occupational accident report identifier (rowFuratNumber)
    DateTime DATETIME NULL,
    Zone VARCHAR(2) NULL,
    AccLocation NVARCHAR(255) NULL,

    -- Accident Geography
    StateCode VARCHAR(10) NULL,
    State NVARCHAR(100) NULL,           -- Populated via namefield
    MunicipalCode VARCHAR(10) NULL,
    Municipality NVARCHAR(100) NULL,    -- Populated via namefield

    -- Event Nature & Condition
    SubType VARCHAR(2) NULL,
    Condition VARCHAR(2) NULL,

    -- Vehicle Info (SOAT & SIRAS)
    Insurance VARCHAR(2) NULL,
    VehicleType VARCHAR(2) NULL,
    LicensePlate VARCHAR(10) NULL,
    InsuranceCode VARCHAR(6) NULL,
    Policy VARCHAR(20) NULL,
    Limit BIT NULL,
    PolicyStart DATE NULL,
    PolicyEnd DATE NULL,
    RegistroSIRAS NVARCHAR(60) NULL,    -- Upstream SIRAS notification ID for SOAT claims

    -- Owner Info
    DocumentType VARCHAR(5) NULL,       -- Supports CC, CE, TI, PA, PEP, PPT
    DocumentNumber VARCHAR(20) NULL,
    OwnerName NVARCHAR(30) NULL,
    OwnerSecondName NVARCHAR(30) NULL,
    OwnerMiddleName NVARCHAR(30) NULL,
    OwnerLastName NVARCHAR(30) NULL,
    OwnerAddress NVARCHAR(100) NULL,
    OwnerPhone VARCHAR(20) NULL,
    OwnerStateCode VARCHAR(10) NULL,
    OwnerState NVARCHAR(100) NULL,          -- Populated via namefield
    OwnerMunicipalityCode VARCHAR(10) NULL,
    OwnerMunicipality NVARCHAR(100) NULL,   -- Populated via namefield

    -- Driver Info
    DriverDocumentType VARCHAR(5) NULL,     -- Supports CC, CE, TI, PA, PEP, PPT
    DriverDocumentNumber VARCHAR(20) NULL,
    DriverName NVARCHAR(30) NULL,
    DriverSecondName NVARCHAR(30) NULL,
    DriverMiddleName NVARCHAR(30) NULL,
    DriverLastName NVARCHAR(30) NULL,
    DriverAddress NVARCHAR(100) NULL,
    DriverTelephone VARCHAR(20) NULL,
    DriverStateCode VARCHAR(10) NULL,
    DriverState NVARCHAR(100) NULL,         -- Populated via namefield
    DriverMunicipalCode VARCHAR(10) NULL,
    DriverMunicipality NVARCHAR(100) NULL,  -- Populated via namefield

    -- Standard Tracking Fields
    CreatedDate DATETIME NOT NULL CONSTRAINT DF_Accident_CreatedDate DEFAULT GETDATE(),
    CreatedBy NVARCHAR(100) NULL,
    ModifiedDate DATETIME NULL,
    ModifiedBy NVARCHAR(100) NULL,

    CONSTRAINT PK_Accident PRIMARY KEY CLUSTERED (AccidentGuid)
);
GO

-- Index on PatientVisit for fast lookups when loading the tabmodal
CREATE NONCLUSTERED INDEX IX_Accident_PatientVisit
    ON dbo.Accident (PatientVisit);
GO