-- GetAccidents.sql
CREATE PROCEDURE dbo.ColGetAccidents
    @AccidentGuid NVARCHAR(50),
    @PatientVisit NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 
        AccidentGuid,
        PatientVisitGuid,
        AccidentType,
        Description,
        Arl,
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
        DriverMunicipality
    FROM dbo.Accident
    WHERE (@AccidentGuid IS NULL Or AccidentGuid = @AccidentGuid)
    AND   (@PatientVisit IS NULL Or PatientVisit = @PatientVisit);
END;
GO