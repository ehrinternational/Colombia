USE [ClinicalGeniusSupplyChain]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[COLCreateRipsRecord]
    @InvoiceGuid NVARCHAR(50),
    @FacilityId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @InvoiceNumber NVARCHAR(20),
            @PatientVisit NVARCHAR(50),
            @PatientId NVARCHAR(50),
            @ClaimGuid NVARCHAR(50),
            @RipsGuid NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50)),
            @VisitLocationId NVARCHAR(50),
            @CodPrestador  NVARCHAR(20),
            @NumDocumentoPrestador  NVARCHAR(20),
            @ResolvedPrincipalDiagnosis VARCHAR(10) = NULL,
            @ResolvedPrincipalDiagnosisCIE11 VARCHAR(256) = NULL,
            @ResolvedNomPrincipalCIE11 NVARCHAR(1000) = NULL,
            @ResolvedRelatedDiagnosis1CIE11 VARCHAR(256) = NULL,
            @ResolvedNomRelated1CIE11 NVARCHAR(1000) = NULL,
            @ResolvedComplicationCIE11 VARCHAR(256) = NULL,
            @ResolvedNomComplicationCIE11 NVARCHAR(1000) = NULL,
            @IsSOATPolicyholder BIT = 0,
            @CodigoVIDA NVARCHAR(256) = NULL;

    DECLARE @LockedTransactions TABLE (
        TransactionGuid NVARCHAR(50),
        PatientVisit NVARCHAR(50),
        SurgeryGuid NVARCHAR(50),
        TransactionType NVARCHAR(50),
        NetAmount DECIMAL(18,4),
        DispensingValue DECIMAL(18,2),
        TransactionQuantity DECIMAL(18,4),
        ExternalProcessedDateTime DATETIME,
        CUMCode NVARCHAR(50),
        CupsCode NVARCHAR(50)
    );

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

    SELECT TOP 1
        @CodPrestador = hsp.NPI,
        @NumDocumentoPrestador = hsp.TaxID
    FROM ClinicalGeniusEhr.dbo.Hospitals hsp WITH(NOLOCK)
    WHERE hsp.LocationId = @VisitLocationId
      AND (hsp.HospitalGuid = @FacilityId  OR hsp.AlternateHospitalGuid = @FacilityId);

    SET @CodPrestador = ISNULL(@CodPrestador, '110010999901');
    SET @NumDocumentoPrestador = ISNULL(@NumDocumentoPrestador, '900123456');

    SELECT TOP 1 
        @ResolvedPrincipalDiagnosis = prob.ProblemCode,
        @ResolvedPrincipalDiagnosisCIE11 = prob.ICD11Code,
        @ResolvedNomPrincipalCIE11 = prob.ICD11Description,
        @ResolvedRelatedDiagnosis1CIE11 = prob.ICD11RelatedCode,
        @ResolvedNomRelated1CIE11 = prob.ICD11RelatedDescription,
        @ResolvedComplicationCIE11 = prob.ICD11ComplicationCode,
        @ResolvedNomComplicationCIE11 = prob.ICD11ComplicationDescription
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

    IF EXISTS (
        SELECT 1 
        FROM ClinicalGeniusSupplyChain.dbo.PayerClaims pyc WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy WITH(NOLOCK) ON ppy.PatientPayerGuid = pyc.PayerGuid
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsurancePlans isp WITH(NOLOCK) ON isp.PlanGuid = ppy.PayerPlan
        INNER JOIN ClinicalGeniusSupplyChain.dbo.InsuranceContracts isc WITH(NOLOCK) ON isc.ContractGuid = isp.ContractGuid
        INNER JOIN ClinicalGeniusSupplyChain.dbo.Payers pyr WITH(NOLOCK) ON pyr.PayerGuid = isc.PayerGuid
        WHERE pyc.ClaimGuid = @ClaimGuid AND pyr.PayerType = '10'
    )
    BEGIN
        SET @IsSOATPolicyholder = 1;
    END

    SELECT TOP 1 @CodigoVIDA = pv.IHCE_VIDACode 
    FROM ClinicalGeniusEhr.dbo.PatientVisits pv WITH(NOLOCK) 
    WHERE pv.PatientVisitUniqueId = @PatientVisit;

    BEGIN TRAN;
    BEGIN TRY
        
        -- 1. Insert RIPS Master Transaction Token
        INSERT INTO ClinicalGeniusSupplyChain.dbo.RipsTransactions (
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
        INSERT INTO ClinicalGeniusSupplyChain.dbo.RipsUsuarios (
            RipsGuid, TipoIdentificacion, NumIdentificacion, TipoUsuario, FechaNacimiento, CodSexo, 
            CodMunicipioResidencia, ZonaTerritorioResidencia, CodPaisOrigen, RegistroSIRAS
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
            ISNULL(adx.ResidencyZone, '01'), 
            ISNULL(adx.CountryOfOrigin, '170'),
            CASE WHEN @IsSOATPolicyholder = 1 THEN ISNULL(pv.SOATRegistryId, 'PENDING-SIRAS') ELSE NULL END
        FROM ClinicalGeniusEhr.dbo.PatientVisits pv WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.PatientTable pt WITH(NOLOCK)
            ON pt.RecordUniqueId = pv.PatientId
        OUTER APPLY
            (SELECT TOP 1 
                ISNULL(adr.BarangayCode,'') AS MunicipalityCode,
                ISNULL(adr.CountryCode,'170') AS CountryOfOrigin,
                CASE 
                    WHEN adr.County IN ('Urbana', 'U', '1', '01') THEN '01'
                    WHEN adr.County IN ('Rural', 'R', '2', '02') THEN '02'
                    ELSE '01' 
                END AS ResidencyZone
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
        WHERE pv.PatientVisitUniqueId = @PatientVisit;

        -- 3. Filter and Stamp Transactions
        UPDATE pt
        SET 
            pt.RIPSBatchId = @RipsGuid,
            pt.CurrentWorkflowStatus = 
                CASE 
                    WHEN pt.TransactionType = 'Honorary' THEN 'Batched for RIPS' 
                    ELSE ISNULL(pt.CurrentWorkflowStatus, 'Batched for RIPS') 
                END
        OUTPUT 
            INSERTED.TransactionGuid,
            INSERTED.PatientVisit,
            INSERTED.SurgeryGuid,
            INSERTED.TransactionType,
            INSERTED.NetAmount,
            INSERTED.DispensingValue,
            INSERTED.TransactionQuantity,
            INSERTED.ExternalProcessedDateTime,
            INSERTED.CUMCode,
            INSERTED.CupsCode
        INTO @LockedTransactions
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(ROWLOCK, UPDLOCK, READPAST)
        WHERE pt.ClaimGuid = @ClaimGuid
          AND pt.Facility = @FacilityId
          AND pt.Status = 'Active'
          AND pt.RIPSBatchId IS NULL
          AND (
              pt.TransactionType <> 'Honorary' 
              OR pt.CurrentWorkflowStatus = 'Batched for DIAN'
              OR pt.CurrentWorkflowStatus IS NULL
          );

        -- 4. Extract locked active items into RipsServicios (Isolating Base Cost vs. Dispensing Fee)
        INSERT INTO ClinicalGeniusSupplyChain.dbo.RipsServicios (
            RipsGuid, TransactionGuid, ServiceCategory, CodServicio, Cantidad, 
            ValorUnitario, ValorTotal, ValorDispensacion, ConceptoRecaudo, ValorCuota, FechaPrestacion, 
            DiagnosticoPrincipal, DiagnosticoPrincipalCIE11, NomDiagnosticoPrincipalCIE11,
            DiagnosticoRelacionado1CIE11, NomDiagnosticoRelacionado1CIE11,
            ComplicacionCIE11, NomComplicacionCIE11,
            FinalidadTecnologia, CodigoVIDA
        )
        SELECT 
            @RipsGuid,
            pt.TransactionGuid,
            CASE 
                WHEN pt.TransactionType IN ('Surgery', 'Procedure', 'BundleMaster', 'Honorary', 'RoomRights', 'Laboratory', 'Imaging') THEN 'Procedimientos'
                WHEN pt.TransactionType = 'Medication' THEN 'Medicamentos'
                ELSE 'OtrosServicios'
            END AS ServiceCategory,
            CASE WHEN pt.TransactionType = 'Medication' THEN pt.CUMCode ELSE pt.CupsCode END AS CodServicio,
            pt.TransactionQuantity,
            -- Unit value derived from base cost excluding dispensing fee
            CASE WHEN pt.TransactionQuantity > 0 THEN ((pt.NetAmount - ISNULL(pt.DispensingValue, 0.00)) / pt.TransactionQuantity) ELSE (pt.NetAmount - ISNULL(pt.DispensingValue, 0.00)) END AS ValorUnitario,
            -- ValorTotal strictly excludes the dispensing fee per Resolution 948
            (pt.NetAmount - ISNULL(pt.DispensingValue, 0.00)) AS ValorTotal, 
            -- ValorDispensacion isolates the explicit fee
            ISNULL(pt.DispensingValue, 0.00) AS ValorDispensacion,
            '05' AS ConceptoRecaudo, 
            0.00 AS ValorCuota, 
            pt.ExternalProcessedDateTime,
            @ResolvedPrincipalDiagnosis AS DiagnosticoPrincipal,
            @ResolvedPrincipalDiagnosisCIE11 AS DiagnosticoPrincipalCIE11,
            @ResolvedNomPrincipalCIE11 AS NomDiagnosticoPrincipalCIE11,
            @ResolvedRelatedDiagnosis1CIE11 AS DiagnosticoRelacionado1CIE11,
            @ResolvedNomRelated1CIE11 AS NomDiagnosticoRelated1CIE11,
            @ResolvedComplicationCIE11 AS ComplicacionCIE11,
            @ResolvedNomComplicationCIE11 AS NomComplicacionCIE11,
            ISNULL(pv.mdlAdmit_AmbulanceID, '44') AS FinalidadTecnologia,
            @CodigoVIDA AS CodigoVIDA
        FROM @LockedTransactions pt
        INNER JOIN ClinicalGeniusEhr.dbo.PatientVisits pv WITH(NOLOCK)
            ON pv.PatientVisitUniqueId = pt.PatientVisit;

        COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        THROW;
    END CATCH;
END;
GO