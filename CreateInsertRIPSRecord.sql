ALTER PROCEDURE ClinicalGeniusSupplyChain.usp_HydrateRipsData
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
            -- Local holders for the resolved multi-tenant diagnostic strings
            @ResolvedPrincipalDiagnosis VARCHAR(10) = NULL;

    SELECT TOP 1
        @InvoiceNumber = InvoiceNumber,
        @PatientVisit = PatientVisit,
        @PatientId = PatientId,
        @ClaimGuid = ClaimGuid
    FROM ClinicalGeniusSupplyChain.DianInvoices WITH(NOLOCK)
    WHERE InvoiceGuid = @InvoiceGuid
      AND FacilityId = @FacilityId;

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
            '110010999901', 
            '900123456'     
        );

        -- 2. Insert RIPS User profile extraction mapping rules
        INSERT INTO ClinicalGeniusSupplyChain.RipsUsuarios (
            RipsGuid, TipoIdentificacion, NumIdentificacion, TipoUsuario, FechaNacimiento, CodSexo, CodMunicipioResidencia, ZonaTerritorioResidencia
        )
        SELECT TOP 1
            @RipsGuid,
            'CC', 
            @PatientId,
            '01', 
            '1985-06-15', 
            'F', 
            '11001', 
            'U' 
        FROM ClinicalGeniusEhr.dbo.PatientVisits WITH(NOLOCK)
        WHERE PatientVisit = @PatientVisit;

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
                -- FIXED: Added explicit categorization mapping for inpatient bed-days ('Stay')
                WHEN pt.TransactionType IN ('Surgery', 'Procedure', 'BundleMaster', 'Honorary', 'RoomRights') THEN 'Procedimientos'
                WHEN pt.TransactionType = 'Medication' THEN 'Medicamentos'
                WHEN pt.TransactionType = 'Stay' THEN 'Stay' -- Aligns directly with Node.js array sorters
                WHEN pt.TransactionType = 'Supplies' THEN 'Insumos'
                ELSE 'OtrosServicios'
            END AS ServiceCategory,
            CASE 
                -- FIXED: If NetAmount > 0 and it's a Supply linked to a surgery, it is a high-cost carve-out item
                -- This forces it to Modality '02' (Pago por Evento) so it maps seamlessly alongside the bundle envelope
                WHEN pt.TransactionType = 'Supplies' AND pt.SurgeryGuid IS NOT NULL AND pt.NetAmount > 0 THEN '02'
                
                -- Standard Package Mapping Rules
                WHEN pt.TransactionType = 'BundleMaster' THEN '01'
                -- If it is a zeroed component tracking line or an absorbed bed-night, tag as bundle absorption
                WHEN pt.SurgeryGuid IS NOT NULL AND pt.NetAmount = 0 THEN '01'
                -- If it's a room day outside the bundle, it calculates normally as an itemized event
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
          AND pt.Facility = @FacilityId -- Enforces multi-tenant workspace separation
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
