USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLCreateRipsRecord ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE {odata}.{COLCreateRipsRecord}
    @InvoiceGuid NVARCHAR(50),
    @FacilityId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Extract master configuration parameters from the source invoice header block
    DECLARE @InvoiceNumber NVARCHAR(20),
            @PatientVisit NVARCHAR(50),
            @PatientId NVARCHAR(50),
            @ClaimGuid NVARCHAR(50),
            @RipsGuid NVARCHAR(50) = NEWID(),
            @VisitLocationId NVARCHAR(50),
            @CodPrestador  NVARCHAR(20),
            @NumDocumentoPrestador  NVARCHAR(20),
            -- Local holders for the resolved multi-tenant diagnostic strings
            @ResolvedPrincipalDiagnosis VARCHAR(10) = NULL;

    -- FIXED: Added missing comma between @ClaimGuid and @VisitLocationId assignments
    SELECT TOP 1
        @InvoiceNumber = dii.InvoiceNumber,
        @PatientVisit = dii.PatientVisit,
        @PatientId = dii.PatientId,
        @ClaimGuid = dii.ClaimGuid,
        @VisitLocationId = pvt.LocationId
    FROM ClinicalGeniusSupplyChain.dbo.DianInvoices dii WITH(NOLOCK)
    INNER JOIN ClinicalGeniusEhr.dbo.PatientVisits  pvt WITH(NOLOCK)
        ON pvt.PatientVisitUniqueId = dii.PatientVisit
    WHERE dii.InvoiceGuid = @InvoiceGuid
      AND dii.FacilityId = @FacilityId;

    -- Get the facility codes from the hospital record with safe fallbacks
    SELECT TOP 1
        @CodPrestador = hsp.NPI,
        @NumDocumentoPrestador = hsp.TaxID
    FROM ClinicalGeniusEhr.dbo.Hospitals hsp WITH(NOLOCK)
    WHERE hsp.LocationId = @VisitLocationId
      AND (hsp.HospitalGuid = @FacilityId  OR hsp.AlternateHospitalGuid = @FacilityId);

    SET @CodPrestador = ISNULL(@CodPrestador, '110010999901');
    SET @NumDocumentoPrestador = ISNULL(@NumDocumentoPrestador, '900123456');

    -- ==========================================================================================
    -- DIAGNOSTIC MATRIX EXTRACTION RULE: Resolve the compliance diagnostic code per patient visit
    -- ==========================================================================================
    SELECT TOP 1 @ResolvedPrincipalDiagnosis = prob.ProblemCode
    FROM ClinicalGeniusEhr.dbo.PatientProblems prob WITH(NOLOCK)
    WHERE prob.PatientVisit = @PatientVisit
      AND prob.Status = 'Active'
    ORDER BY 
        CASE 
            WHEN prob.ProblemType = 'Principal Diagnosis' THEN 1
            WHEN prob.ProblemType = 'Discharge Diagnosis' THEN 2
            WHEN prob.ProblemType = 'Final Diagnosis'     THEN 3
            WHEN prob.ProblemType = 'Working Diagnosis'   THEN 4
            WHEN prob.ProblemType = 'Admitting Diagnosis' THEN 5
            ELSE 6
        END ASC,
        prob.ProblemDateTimeDocumented DESC, 
        prob.ProblemGuid ASC;

    SET @ResolvedPrincipalDiagnosis = ISNULL(@ResolvedPrincipalDiagnosis, 'R69X');

    -- Open atomic transaction block to safely seed the RIPS ledgers
    BEGIN TRAN;
    BEGIN TRY
        
        -- 1. Insert RIPS Master Transaction Token
        INSERT INTO ClinicalGeniusSupplyChain.RipsTransactions (
            RipsGuid, InvoiceGuid, FacilityId, NumFactura, CodPrestador, NumDocumentoPrestador
        )
        VALUES (
            @RipsGuid,
            @InvoiceGuid,
            @FacilityId,
            @InvoiceNumber,
            @CodPrestador, 
            @NumDocumentoPrestador     
        );

        -- 2. Insert RIPS User profile extraction mapping rules
        INSERT INTO ClinicalGeniusSupplyChain.RipsUsuarios (
            RipsGuid, TipoIdentificacion, NumIdentificacion, TipoUsuario, FechaNacimiento, CodSexo, CodMunicipioResidencia, ZonaTerritorioResidencia
        )
        SELECT TOP 1
            @RipsGuid,
            ISNULL(pt.PrimaryIdNumber, 'CC'), 
            ISNULL(pt.MedicalRecordNumber, '1001'),
            ISNULL(pyx.PayerType,'01'), 
            pt.PatientDOB, 
            CASE 
                WHEN pt.PatientSex LIKE 'M%' THEN 'M'
                WHEN pt.PatientSex LIKE 'F%' THEN 'F'
                ELSE 'I'
            END, 
            ISNULL(adx.MunicipalityCode, '11001'), 
            ISNULL(adx.ResidencyZone, 'U') 
        FROM ClinicalGeniusEhr.dbo.PatientVisits pv WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.PatientTable pt WITH(NOLOCK)
            ON pt.RecordUniqueId = pv.PatientId
        OUTER APPLY
            (SELECT TOP 1 
                ISNULL(adr.BarangayCode,'') AS MunicipalityCode,
                ISNULL(adr.County,'U') AS ResidencyZone
             FROM ClinicalGeniusEhr.dbo.PatientAddresses adr WITH(NOLOCK)
             WHERE adr.Patientid = pv.PatientId
               AND adr.Active = 1
             ORDER BY adr.Selected ASC) adx
        OUTER APPLY
            (SELECT TOP 1 
                pyr.PayerType
             FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
             INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) 
                 ON ppy.PatientPayerGuid = pyc.PayerGuid
             INNER JOIN ClinicalGeniusSupplyChain.dbo.InsurancePlans isp WITH(NOLOCK) 
                 ON isp.PlanGuid = ppy.PayerPlan
             INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) 
                 ON isc.ContractGuid = isp.ContractGuid
             INNER JOIN ClinicalGeniusSupplyChain.dbo.Payers pyr WITH(NOLOCK)
                 ON pyr.PayerGuid = isc.PayerGuid
             WHERE pyc.PatientVisit = @PatientVisit
             ORDER BY pyc.BatchNumber ASC) pyx
        WHERE pv.PatientVisit = @PatientVisit;

        -- 3. Deconstruct and stage active items into the unified services array
        INSERT INTO ClinicalGeniusSupplyChain.RipsServicios (
            RipsGuid, TransactionGuid, SurgeryGuid, ServiceCategory, ModalidadPago, CodServicio, Cantidad, 
            ValorUnitario, ValorTotal, ConceptoRecaudo, ValorCuota, FechaPrestacion, DiagnosticoPrincipal
        )
        SELECT 
            @RipsGuid,
            pt.TransactionGuid,
            pt.SurgeryGuid, 
            CASE 
                WHEN pt.TransactionType IN ('Surgery', 'Procedure', 'BundleMaster', 'Honorary', 'RoomRights') THEN 'Procedimientos'
                WHEN pt.TransactionType = 'Medication' THEN 'Medicamentos'
                WHEN pt.TransactionType = 'Stay' THEN 'Stay' 
                WHEN pt.TransactionType = 'Supplies' THEN 'Insumos'
                ELSE 'OtrosServicios'
            END AS ServiceCategory,
            CASE 
                WHEN pt.TransactionType = 'Supplies' AND pt.SurgeryGuid IS NOT NULL AND pt.NetAmount > 0 THEN '02'
                WHEN pt.TransactionType = 'BundleMaster' THEN '01'
                WHEN pt.SurgeryGuid IS NOT NULL AND pt.NetAmount = 0 THEN '01'
                WHEN pt.TransactionType = 'Stay' AND pt.NetAmount > 0 THEN '02'
                ELSE '02' 
            END AS ModalidadPago,
            CASE WHEN pt.TransactionType = 'Medication' THEN pt.CUMCode ELSE pt.CupsCode END AS CodServicio,
            pt.Quantity,
            pt.BaseUnitValue,
            pt.NetAmount AS ValorTotal, 
            '05' AS ConceptoRecaudo, 
            0.00, 
            pt.ExternalProcessedDateTime,
            @ResolvedPrincipalDiagnosis AS DiagnosticoPrincipal
        FROM ClinicalGeniusSupplyChain.PatientTransactions pt WITH(NOLOCK)
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Status = 'Active'
          AND pt.Facility = @FacilityId 
          AND ((@ClaimGuid IS NULL AND pt.ClaimGuid IS NULL) OR (@ClaimGuid IS NOT NULL AND pt.ClaimGuid = @ClaimGuid));

        COMMIT TRAN;

        SELECT @RipsGuid AS HydratedRipsGuid, @InvoiceNumber AS TargetInvoiceNumber, @ResolvedPrincipalDiagnosis AS AppliedDiagnosticCode;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrorSeverity INT = ERROR_SEVERITY(),
                @ErrorState INT = ERROR_STATE();
                
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO