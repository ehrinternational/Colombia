-- InsertAccidents.sql
CREATE PROCEDURE dbo.COLInsertAccidents
    @AccidentGuid NVARCHAR(50),
    @PatientVisitGuid NVARCHAR(50),
    @AccidentType INT = NULL,
    @Description VARCHAR(500) = NULL,
    @Arl BIT = NULL,
    @FuratNumber VARCHAR(20) = NULL,
    @DateTime DATETIME = NULL,
    @Zone VARCHAR(2) = NULL,
    @AccLocation VARCHAR(255) = NULL,
    @StateCode VARCHAR(10) = NULL,
    @State VARCHAR(100) = NULL,
    @MunicipalCode VARCHAR(10) = NULL,
    @Municipality VARCHAR(100) = NULL,
    @SubType VARCHAR(2) = NULL,
    @Condition VARCHAR(2) = NULL,
    @Insurance VARCHAR(2) = NULL,
    @VehicleType VARCHAR(2) = NULL,
    @LicensePlate VARCHAR(10) = NULL,
    @InsuranceCode VARCHAR(6) = NULL,
    @Policy VARCHAR(20) = NULL,
    @Limit BIT = NULL,
    @PolicyStart DATE = NULL,
    @PolicyEnd DATE = NULL,
    @DocumentType VARCHAR(2) = NULL,
    @DocumentNumber VARCHAR(20) = NULL,
    @OwnerName VARCHAR(30) = NULL,
    @OwnerSecondName VARCHAR(30) = NULL,
    @OwnerMiddleName VARCHAR(30) = NULL,
    @OwnerLastName VARCHAR(30) = NULL,
    @OwnerAddress VARCHAR(100) = NULL,
    @OwnerPhone VARCHAR(10) = NULL,
    @OwnerStateCode VARCHAR(10) = NULL,
    @OwnerState VARCHAR(100) = NULL,
    @OwnerMunicipalityCode VARCHAR(10) = NULL,
    @OwnerMunicipality VARCHAR(100) = NULL,
    @DriverDocumentType VARCHAR(2) = NULL,
    @DriverDocumentNumber VARCHAR(20) = NULL,
    @DriverName VARCHAR(30) = NULL,
    @DriverSecondName VARCHAR(30) = NULL,
    @DriverMiddleName VARCHAR(30) = NULL,
    @DriverLastName VARCHAR(30) = NULL,
    @DriverAddress VARCHAR(100) = NULL,
    @DriverTelephone VARCHAR(10) = NULL,
    @DriverStateCode VARCHAR(10) = NULL,
    @DriverState VARCHAR(100) = NULL,
    @DriverMunicipalCode VARCHAR(10) = NULL,
    @DriverMunicipality VARCHAR(100) = NULL,
    @CreatedBy VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.Accident (
        AccidentGuid, PatientVisitGuid, AccidentType, Description, Arl, FuratNumber, DateTime, Zone, AccLocation,
        StateCode, State, MunicipalCode, Municipality, SubType, Condition,
        Insurance, VehicleType, LicensePlate, InsuranceCode, Policy, Limit, PolicyStart, PolicyEnd,
        DocumentType, DocumentNumber, OwnerName, OwnerSecondName, OwnerMiddleName, OwnerLastName, 
        OwnerAddress, OwnerPhone, OwnerStateCode, OwnerState, OwnerMunicipalityCode, OwnerMunicipality,
        DriverDocumentType, DriverDocumentNumber, DriverName, DriverSecondName, DriverMiddleName, 
        DriverLastName, DriverAddress, DriverTelephone, DriverStateCode, DriverState, DriverMunicipalCode, 
        DriverMunicipality, CreatedDate, CreatedBy
    )
    VALUES (
        @AccidentGuid, @PatientVisitGuid, @AccidentType, @Description, @Arl, @FuratNumber, @DateTime, @Zone, @AccLocation,
        @StateCode, @State, @MunicipalCode, @Municipality, @SubType, @Condition,
        @Insurance, @VehicleType, @LicensePlate, @InsuranceCode, @Policy, @Limit, @PolicyStart, @PolicyEnd,
        @DocumentType, @DocumentNumber, @OwnerName, @OwnerSecondName, @OwnerMiddleName, @OwnerLastName, 
        @OwnerAddress, @OwnerPhone, @OwnerStateCode, @OwnerState, @OwnerMunicipalityCode, @OwnerMunicipality,
        @DriverDocumentType, @DriverDocumentNumber, @DriverName, @DriverSecondName, @DriverMiddleName, 
        @DriverLastName, @DriverAddress, @DriverTelephone, @DriverStateCode, @DriverState, @DriverMunicipalCode, 
        @DriverMunicipality, GETDATE(), @CreatedBy
    );
END;
GO