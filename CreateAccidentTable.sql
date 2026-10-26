CREATE TABLE dbo.Accident (
    AccidentGuid NVARCHAR(50) NOT NULL PRIMARY KEY,
    PatientVisit NVARCHAR(50) NOT NULL, -- Referenced in appendinsert
    AccidentType INT NULL, -- Derived from AdmissionType

    -- Accident General Info
    Description VARCHAR(500) NULL,
    Arl BIT NULL,
    ArlNumber VARCHAR(20) NULL, 
    DateTime DATETIME NULL,
    Zone VARCHAR(2) NULL,
    AccLocation VARCHAR(255) NULL, 
    
    -- Accident Geography
    StateCode VARCHAR(10) NULL,
    State VARCHAR(100) NULL, -- Populated via namefield
    MunicipalCode VARCHAR(10) NULL,
    Municipality VARCHAR(100) NULL, -- Populated via namefield

    -- Event Nature & Condition
    SubType VARCHAR(2) NULL,
    Condition VARCHAR(2) NULL,

    -- Vehicle Info (SOAT)
    Insurance VARCHAR(2) NULL,
    VehicleType VARCHAR(2) NULL,
    LicensePlate VARCHAR(10) NULL,
    InsuranceCode VARCHAR(6) NULL,
    Policy VARCHAR(20) NULL,
    Limit BIT NULL,
    PolicyStart DATE NULL,
    PolicyEnd DATE NULL,

    -- Owner Info
    DocumentType VARCHAR(2) NULL,
    DocumentNumber VARCHAR(20) NULL,
    OwnerName VARCHAR(30) NULL,
    OwnerSecondName VARCHAR(30) NULL,
    OwnerMiddleName VARCHAR(30) NULL,
    OwnerLastName VARCHAR(30) NULL,
    OwnerAddress VARCHAR(100) NULL,
    OwnerPhone VARCHAR(10) NULL,
    OwnerStateCode VARCHAR(10) NULL,
    OwnerState VARCHAR(100) NULL, -- Populated via namefield
    OwnerMunicipalityCode VARCHAR(10) NULL,
    OwnerMunicipality VARCHAR(100) NULL, -- Populated via namefield

    -- Driver Info
    DriverDocumentType VARCHAR(2) NULL,
    DriverDocumentNumber VARCHAR(20) NULL,
    DriverName VARCHAR(30) NULL,
    DriverSecondName VARCHAR(30) NULL,
    DriverMiddleName VARCHAR(30) NULL,
    DriverLastName VARCHAR(30) NULL,
    DriverAddress VARCHAR(100) NULL,
    DriverTelephone VARCHAR(10) NULL,
    DriverStateCode VARCHAR(10) NULL,
    DriverState VARCHAR(100) NULL, -- Populated via namefield
    DriverMunicipalCode VARCHAR(10) NULL,
    DriverMunicipality VARCHAR(100) NULL, -- Populated via namefield

    -- Standard Tracking Fields
    CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
    CreatedBy VARCHAR(100) NULL,
    ModifiedDate DATETIME NULL,
    ModifiedBy VARCHAR(100) NULL
);
GO

-- Optional: Index on PatientVisitGuid for faster lookups when loading the tabmodal
CREATE NONCLUSTERED INDEX IX_Accident_PatientVisitGuid 
ON dbo.Accident (PatientVisitGuid);
GO