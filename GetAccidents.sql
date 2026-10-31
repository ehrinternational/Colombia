-- ==========================================================================================
-- GET ACCIDENT RECORDS (TABMODAL RETRIEVAL)
-- TARGET ARCHITECTURE: SQL Server 2014+ / Azure SQL Database
-- ==========================================================================================

IF OBJECT_ID('dbo.ColGetAccidents', 'P') IS NOT NULL
    DROP PROCEDURE dbo.ColGetAccidents;
GO

CREATE PROCEDURE dbo.ColGetAccidents
    @AccidentGuid NVARCHAR(50) = NULL,
    @PatientVisit NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        AccidentGuid,
        PatientVisit,
        AccidentType,
        Description,
        Arl,
        ArlNumber,
        FuratNumber,
        DateTime,
        Zone,
        AccLocation,
        StateCode,
        State,
        MunicipalCode,
        Municipality,
        SubType,
        Condition,
        Insurance,
        VehicleType,
        LicensePlate,
        InsuranceCode,
        Policy,
        Limit,
        PolicyStart,
        PolicyEnd,
        RegistroSIRAS,
        DocumentType,
        DocumentNumber,
        OwnerName,
        OwnerSecondName,
        OwnerMiddleName,
        OwnerLastName,
        OwnerAddress,
        OwnerPhone,
        OwnerStateCode,
        OwnerState,
        OwnerMunicipalityCode,
        OwnerMunicipality,
        DriverDocumentType,
        DriverDocumentNumber,
        DriverName,
        DriverSecondName,
        DriverMiddleName,
        DriverLastName,
        DriverAddress,
        DriverTelephone,
        DriverStateCode,
        DriverState,
        DriverMunicipalCode,
        DriverMunicipality,
        CreatedDate,
        CreatedBy,
        ModifiedDate,
        ModifiedBy
    FROM dbo.Accident
    WHERE (@AccidentGuid IS NOT NULL OR @PatientVisit IS NOT NULL)
      AND (@AccidentGuid IS NULL OR AccidentGuid = @AccidentGuid)
      AND (@PatientVisit IS NULL OR PatientVisit = @PatientVisit);
END;
GO
