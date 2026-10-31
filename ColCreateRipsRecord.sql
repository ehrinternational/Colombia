SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'[dbo].[COLCreateRipsRecord]', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE [dbo].[COLCreateRipsRecord] AS BEGIN SET NOCOUNT ON; END');
GO

-- ==========================================================================================
-- Procedure: [dbo].[COLCreateRipsRecord]
-- Purpose: Atomically validates a DIAN sales invoice, locks its batched PatientTransactions,
--          and populates RipsTransactions, RipsUsuarios, and RipsServicios in compliance
--          with Minsalud Resolution 948 / FEV-RIPS monetary parity rules.
-- Target: SQL Server 2014+
-- ==========================================================================================
ALTER PROCEDURE [dbo].[COLCreateRipsRecord]
    @InvoiceGuid NVARCHAR(50),
    @FacilityId  NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @InvoiceGuid = LTRIM(RTRIM(@InvoiceGuid));
    SET @FacilityId = LTRIM(RTRIM(@FacilityId));

    IF NULLIF(@InvoiceGuid, N'') IS NULL
        THROW 50001, N'Validation Failure: @InvoiceGuid is required.', 1;

    IF NULLIF(@FacilityId, N'') IS NULL
        THROW 50002, N'Validation Failure: @FacilityId is required.', 1;

    DECLARE @TranCount INT = @@TRANCOUNT;
    DECLARE @RipsGuid NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50));

    DECLARE @InvoiceNumber NVARCHAR(20),
            @InvoiceType VARCHAR(5),
            @DianStatus NVARCHAR(50),
            @InvoiceIssueDate DATETIME,
            @InvoiceCopayOrCuota DECIMAL(18,2) = 0.00,
            @PatientVisit NVARCHAR(50),
            @PatientId NVARCHAR(50),
            @ClaimGuid NVARCHAR(50);

    DECLARE @VisitLocationId NVARCHAR(50),
            @VisitPatientId NVARCHAR(50),
            @EffectivePatientId NVARCHAR(50),
            @CodigoVIDA NVARCHAR(256) = NULL,
            @SOATRegistryId NVARCHAR(100) = NULL,
            @FinalidadTecnologia VARCHAR(10) = '44';

    DECLARE @CodPrestador NVARCHAR(20),
            @NumDocumentoPrestador NVARCHAR(20);

    DECLARE @ResolvedPrincipalDiagnosis VARCHAR(10) = NULL,
            @ResolvedPrincipalDiagnosisCIE11 VARCHAR(256) = NULL,
            @ResolvedNomPrincipalCIE11 NVARCHAR(1000) = NULL,
            @ResolvedRelatedDiagnosis1CIE11 VARCHAR(256) = NULL,
            @ResolvedNomRelated1CIE11 NVARCHAR(1000) = NULL,
            @ResolvedComplicationCIE11 VARCHAR(256) = NULL,
            @ResolvedNomComplicationCIE11 NVARCHAR(1000) = NULL;

    DECLARE @ResolvedPayerType VARCHAR(10) = '01',
            @IsSOATPolicyholder BIT = 0,
            @ClaimCopay DECIMAL(18,2) = 0.00,
            @ClaimCoinsurance DECIMAL(18,2) = 0.00,
            @EffectiveCopayTotal DECIMAL(18,2) = 0.00,
            @DefaultConceptoRecaudo VARCHAR(2) = '05',
            @HasInvoiceStampedRows BIT = 0;

    DECLARE @LockedTransactions TABLE (
        TransactionGuid           NVARCHAR(50),
        PatientVisit              NVARCHAR(50),
        SurgeryGuid               NVARCHAR(50),
        TransactionType           NVARCHAR(50),
        NetAmount                 DECIMAL(18,4),
        DispensingValue           DECIMAL(18,2),
        TransactionQuantity       DECIMAL(18,4),
        ExternalProcessedDateTime DATETIME,
        DateTimeEntered           DATETIME,
        CUMCode                   NVARCHAR(50),
        CupsCode                  NVARCHAR(50)
    );

    BEGIN TRY
        IF @TranCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION sp_COLCreateRipsRecord;

        -- 1. Lock and validate the target DIAN invoice under tenant isolation
        SELECT TOP (1)
            @InvoiceNumber = dii.InvoiceNumber,
            @InvoiceType = dii.InvoiceType,
            @DianStatus = dii.DianStatus,
            @InvoiceIssueDate = CAST(dii.IssueDateTime AS DATETIME),
            @InvoiceCopayOrCuota = ROUND(ISNULL(dii.CopayOrCuotaAmount, 0.00), 2),
            @PatientVisit = dii.PatientVisit,
            @PatientId = dii.PatientId,
            @ClaimGuid = dii.ClaimGuid
        FROM [dbo].[DianInvoices] dii WITH (UPDLOCK, HOLDLOCK)
        WHERE dii.InvoiceGuid = @InvoiceGuid
          AND dii.FacilityId = @FacilityId;

        IF @@ROWCOUNT = 0 OR NULLIF(LTRIM(RTRIM(@InvoiceNumber)), N'') IS NULL
            THROW 50003, N'Validation Failure: Target InvoiceGuid was not found for this FacilityId.', 1;

        IF @InvoiceType <> '01'
            THROW 50004, N'Validation Failure: RIPS records can only be generated from a sales invoice (InvoiceType ''01'').', 1;

        IF ISNULL(@DianStatus, N'') IN (N'Cancelled', N'Voided', N'Rejected')
            THROW 50005, N'Validation Failure: Cannot generate RIPS for a cancelled, voided, or rejected DIAN invoice.', 1;

        IF EXISTS (
            SELECT 1
            FROM [dbo].[RipsTransactions] rt WITH (UPDLOCK, HOLDLOCK)
            WHERE rt.InvoiceGuid = @InvoiceGuid
              AND rt.FacilityId = @FacilityId
        )
            THROW 50006, N'Validation Failure: A RIPS record already exists for this InvoiceGuid.', 1;

        -- 2. Resolve Visit context, Provider REPS/NIT, Principal/CIE-11 Diagnoses, and Claim PayerType
        SELECT TOP (1)
            @VisitLocationId = pv.LocationId,
            @VisitPatientId = pv.PatientId,
            @CodigoVIDA = NULLIF(LTRIM(RTRIM(pv.IHCE_VIDACode)), N''),
            @SOATRegistryId = NULLIF(LTRIM(RTRIM(pv.SOATRegistryId)), N''),
            @FinalidadTecnologia = CASE
                WHEN LEN(LTRIM(RTRIM(ISNULL(pv.mdlAdmit_AmbulanceID, N'')))) = 2
                     AND LTRIM(RTRIM(pv.mdlAdmit_AmbulanceID)) NOT LIKE N'%[^0-9]%'
                THEN CAST(LTRIM(RTRIM(pv.mdlAdmit_AmbulanceID)) AS VARCHAR(10))
                ELSE '44'
            END
        FROM ClinicalGeniusEhr.dbo.PatientVisits pv
        WHERE pv.PatientVisitUniqueId = @PatientVisit;

        IF @@ROWCOUNT = 0
            THROW 50007, N'Validation Failure: Linked PatientVisit was not found in ClinicalGeniusEhr.dbo.PatientVisits.', 1;

        SET @EffectivePatientId = COALESCE(NULLIF(LTRIM(RTRIM(@VisitPatientId)), N''), NULLIF(LTRIM(RTRIM(@PatientId)), N''));

        SELECT TOP (1)
            @CodPrestador = LEFT(NULLIF(LTRIM(RTRIM(hsp.NPI)), N''), 20),
            @NumDocumentoPrestador = LEFT(NULLIF(LTRIM(RTRIM(hsp.TaxID)), N''), 20)
        FROM ClinicalGeniusEhr.dbo.Hospitals hsp
        WHERE (hsp.HospitalGuid = @FacilityId OR hsp.AlternateHospitalGuid = @FacilityId)
        ORDER BY
            CASE WHEN @VisitLocationId IS NOT NULL AND hsp.LocationId = @VisitLocationId THEN 1 ELSE 2 END ASC,
            hsp.HospitalGuid ASC;

        SET @CodPrestador = ISNULL(@CodPrestador, N'110010999901');
        SET @NumDocumentoPrestador = ISNULL(@NumDocumentoPrestador, N'900123456');

        SELECT TOP (1)
            @ResolvedPrincipalDiagnosis = LEFT(NULLIF(LTRIM(RTRIM(prob.ProblemCode)), ''), 10),
            @ResolvedPrincipalDiagnosisCIE11 = NULLIF(LTRIM(RTRIM(prob.ICD11Code)), ''),
            @ResolvedNomPrincipalCIE11 = NULLIF(LTRIM(RTRIM(prob.ICD11Description)), N''),
            @ResolvedRelatedDiagnosis1CIE11 = NULLIF(LTRIM(RTRIM(prob.ICD11RelatedCode)), ''),
            @ResolvedNomRelated1CIE11 = NULLIF(LTRIM(RTRIM(prob.ICD11RelatedDescription)), N''),
            @ResolvedComplicationCIE11 = NULLIF(LTRIM(RTRIM(prob.ICD11ComplicationCode)), ''),
            @ResolvedNomComplicationCIE11 = NULLIF(LTRIM(RTRIM(prob.ICD11ComplicationDescription)), N'')
        FROM ClinicalGeniusEhr.dbo.PatientProblems prob
        WHERE prob.PatientVisit = @PatientVisit
          AND prob.Status = N'Active'
        ORDER BY
            CASE
                WHEN prob.ProblemType = N'Principal Diagnosis' THEN 1
                WHEN prob.ProblemType = N'Discharge Diagnosis' THEN 2
                WHEN prob.ProblemType = N'Final Diagnosis'     THEN 3
                WHEN prob.ProblemType = N'Working Diagnosis'   THEN 4
                WHEN prob.ProblemType = N'Admitting Diagnosis' THEN 5
                ELSE 6
            END ASC,
            prob.ProblemDateTimeDocumented DESC,
            prob.ProblemGuid ASC;

        SET @ResolvedPrincipalDiagnosis = ISNULL(@ResolvedPrincipalDiagnosis, 'R69X');

        SELECT TOP (1)
            @ResolvedPayerType = COALESCE(NULLIF(LTRIM(RTRIM(pyr.PayerType)), ''), '01'),
            @ClaimCopay = ROUND(ISNULL(pyc.Copay, 0.00), 2),
            @ClaimCoinsurance = ROUND(ISNULL(pyc.MedicalCoinsurance, 0.00), 2)
        FROM [dbo].[PayerClaims] pyc
        LEFT JOIN ClinicalGeniusEhr.dbo.PatientPayers ppy
            ON ppy.PatientPayerGuid = pyc.PayerGuid
        LEFT JOIN [dbo].[InsurancePlans] isp
            ON isp.PlanGuid = ppy.PayerPlan
        LEFT JOIN [dbo].[InsuranceContracts] isc
            ON isc.ContractGuid = isp.ContractGuid
        LEFT JOIN [dbo].[Payers] pyr
            ON pyr.PayerGuid = isc.PayerGuid
        WHERE (pyc.ClaimGuid = @ClaimGuid OR pyc.PatientVisit = @PatientVisit)
        ORDER BY
            CASE WHEN pyc.ClaimGuid = @ClaimGuid THEN 1 ELSE 2 END ASC,
            pyc.BatchNumber ASC;

        SET @IsSOATPolicyholder = CASE WHEN @ResolvedPayerType = '10' THEN 1 ELSE 0 END;
        SET @EffectiveCopayTotal = CASE
            WHEN @InvoiceCopayOrCuota > 0.00 THEN @InvoiceCopayOrCuota
            ELSE ROUND(@ClaimCopay + @ClaimCoinsurance, 2)
        END;
        SET @DefaultConceptoRecaudo = CASE
            WHEN @EffectiveCopayTotal <= 0.00 THEN '05'
            WHEN @ClaimCopay > 0.00 THEN '01'
            ELSE '02'
        END;

        -- 3. Lock and stamp transactions belonging strictly to this DIAN invoice batch
        IF EXISTS (
            SELECT 1
            FROM [dbo].[PatientTransactions] pt WITH (UPDLOCK, HOLDLOCK)
            WHERE pt.DIANInvoiceBatchId = @InvoiceGuid
              AND pt.Facility = @FacilityId
              AND pt.Status = N'Active'
        )
        BEGIN
            SET @HasInvoiceStampedRows = 1;
        END

        UPDATE pt
        SET
            pt.RIPSBatchId = @RipsGuid,
            pt.CurrentWorkflowStatus = CASE
                WHEN pt.TransactionType = N'Honorary' THEN N'Batched for RIPS'
                ELSE ISNULL(NULLIF(LTRIM(RTRIM(pt.CurrentWorkflowStatus)), N''), N'Batched for RIPS')
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
            INSERTED.DateTimeEntered,
            INSERTED.CUMCode,
            INSERTED.CupsCode
        INTO @LockedTransactions
        FROM [dbo].[PatientTransactions] pt WITH (UPDLOCK, ROWLOCK)
        WHERE pt.Facility = @FacilityId
          AND pt.Status = N'Active'
          AND pt.RIPSBatchId IS NULL
          AND (
              (@HasInvoiceStampedRows = 1 AND pt.DIANInvoiceBatchId = @InvoiceGuid)
              OR (
                  @HasInvoiceStampedRows = 0
                  AND pt.ClaimGuid = @ClaimGuid
                  AND pt.DIANInvoiceBatchId IS NULL
                  AND ISNULL(pt.NetAmount, 0) > 0
                  AND (
                      ISNULL(pt.TransactionType, N'') <> N'Honorary'
                      OR pt.CurrentWorkflowStatus IN (N'Approved', N'Batched for DIAN')
                  )
              )
          );

        IF NOT EXISTS (SELECT 1 FROM @LockedTransactions)
            THROW 50008, N'Validation Failure: No eligible unbatched transactions were found for this DIAN invoice.', 1;

        -- 4. Insert RIPS Master Transaction Header
        INSERT INTO [dbo].[RipsTransactions] (
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

        -- 5. Insert RIPS User Profile (prioritizing legal document PtSSN and selected primary address)
        INSERT INTO [dbo].[RipsUsuarios] (
            RipsGuid, TipoIdentificacion, NumIdentificacion, TipoUsuario, FechaNacimiento, CodSexo,
            CodMunicipioResidencia, ZonaTerritorioResidencia, CodPaisOrigen, RegistroSIRAS
        )
        SELECT TOP (1)
            @RipsGuid,
            COALESCE(NULLIF(LTRIM(RTRIM(pt.PrimaryIdNumber)), ''), 'CC'),
            COALESCE(
                NULLIF(LTRIM(RTRIM(pt.PtSSN)), ''),
                NULLIF(LTRIM(RTRIM(pt.MedicalRecordNumber)), ''),
                '1001'
            ),
            @ResolvedPayerType,
            pt.PatientDOB,
            CASE
                WHEN pt.PatientSex LIKE 'M%' THEN 'M'
                WHEN pt.PatientSex LIKE 'F%' THEN 'F'
                ELSE 'I'
            END,
            COALESCE(adx.MunicipalityCode, '11001'),
            COALESCE(adx.ResidencyZone, '01'),
            COALESCE(adx.CountryOfOrigin, '170'),
            CASE
                WHEN @IsSOATPolicyholder = 1 THEN COALESCE(@SOATRegistryId, N'PENDING-SIRAS')
                ELSE NULL
            END
        FROM ClinicalGeniusEhr.dbo.PatientTable pt
        OUTER APPLY (
            SELECT TOP (1)
                NULLIF(LTRIM(RTRIM(adr.BarangayCode)), '') AS MunicipalityCode,
                NULLIF(LTRIM(RTRIM(adr.CountryCode)), '') AS CountryOfOrigin,
                CASE
                    WHEN LTRIM(RTRIM(adr.County)) IN ('Urbana', 'U', '1', '01') THEN '01'
                    WHEN LTRIM(RTRIM(adr.County)) IN ('Rural', 'R', '2', '02') THEN '02'
                    ELSE '01'
                END AS ResidencyZone
            FROM ClinicalGeniusEhr.dbo.PatientAddresses adr
            WHERE (adr.Patientid = pt.RecordUniqueId OR adr.Patientid = @EffectivePatientId)
              AND adr.Active = 1
            ORDER BY adr.Selected DESC, adr.BarangayCode DESC
        ) adx
        WHERE @EffectivePatientId IS NOT NULL
          AND (pt.RecordUniqueId = @EffectivePatientId OR pt.PatientId = @EffectivePatientId)
        ORDER BY
            CASE WHEN pt.RecordUniqueId = @EffectivePatientId THEN 1 ELSE 2 END ASC,
            pt.RecordUniqueId DESC;

        IF @@ROWCOUNT = 0
            THROW 50009, N'Validation Failure: Patient demographic record was not found for RipsUsuarios.', 1;

        -- 6. Insert RipsServicios (isolating Base Cost vs. Dispensing Fee and allocating ValorCuota)
        ;WITH ServiceBase AS (
            SELECT
                pt.TransactionGuid,
                CASE
                    WHEN pt.TransactionType IN (N'Surgery', N'Procedure', N'BundleMaster', N'Honorary', N'RoomRights', N'Laboratory', N'Imaging') THEN N'Procedimientos'
                    WHEN pt.TransactionType = N'Medication' THEN N'Medicamentos'
                    ELSE N'OtrosServicios'
                END AS ServiceCategory,
                CASE
                    WHEN pt.TransactionType = N'Medication' THEN COALESCE(NULLIF(LTRIM(RTRIM(pt.CUMCode)), N''), NULLIF(LTRIM(RTRIM(pt.CupsCode)), N''))
                    ELSE COALESCE(NULLIF(LTRIM(RTRIM(pt.CupsCode)), N''), NULLIF(LTRIM(RTRIM(pt.CUMCode)), N''))
                END AS CodServicio,
                ISNULL(pt.TransactionQuantity, 0.0000) AS Cantidad,
                ROUND(CASE WHEN ISNULL(pt.NetAmount, 0.00) > 0.00 THEN pt.NetAmount ELSE 0.00 END, 2) AS LineInclusiveAmount,
                ROUND(
                    CASE
                        WHEN ISNULL(pt.DispensingValue, 0.00) <= 0.00 THEN 0.00
                        WHEN pt.DispensingValue > ISNULL(pt.NetAmount, 0.00)
                        THEN CASE WHEN ISNULL(pt.NetAmount, 0.00) > 0.00 THEN pt.NetAmount ELSE 0.00 END
                        ELSE pt.DispensingValue
                    END,
                    2
                ) AS ValorDispensacion,
                COALESCE(pt.ExternalProcessedDateTime, pt.DateTimeEntered, @InvoiceIssueDate, SYSDATETIME()) AS FechaPrestacion,
                CASE
                    WHEN LEN(LTRIM(RTRIM(ISNULL(pv_line.mdlAdmit_AmbulanceID, N'')))) = 2
                         AND LTRIM(RTRIM(pv_line.mdlAdmit_AmbulanceID)) NOT LIKE N'%[^0-9]%'
                    THEN CAST(LTRIM(RTRIM(pv_line.mdlAdmit_AmbulanceID)) AS VARCHAR(10))
                    ELSE @FinalidadTecnologia
                END AS LineFinalidad
            FROM @LockedTransactions pt
            LEFT JOIN ClinicalGeniusEhr.dbo.PatientVisits pv_line
                ON pv_line.PatientVisitUniqueId = pt.PatientVisit
        ),
        CopayWaterfall AS (
            SELECT
                sb.TransactionGuid,
                sb.ServiceCategory,
                sb.CodServicio,
                sb.Cantidad,
                ROUND(sb.LineInclusiveAmount - sb.ValorDispensacion, 2) AS ValorTotal,
                sb.ValorDispensacion,
                sb.LineInclusiveAmount,
                ISNULL(
                    SUM(sb.LineInclusiveAmount) OVER (
                        ORDER BY sb.LineInclusiveAmount DESC, sb.TransactionGuid ASC
                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                    ),
                    0.00
                ) AS PriorCapacity,
                sb.FechaPrestacion,
                sb.LineFinalidad
            FROM ServiceBase sb
        ),
        FinalServices AS (
            SELECT
                cw.TransactionGuid,
                cw.ServiceCategory,
                cw.CodServicio,
                cw.Cantidad,
                CASE
                    WHEN cw.Cantidad > 0 THEN ROUND(cw.ValorTotal / cw.Cantidad, 4)
                    ELSE cw.ValorTotal
                END AS ValorUnitario,
                cw.ValorTotal,
                cw.ValorDispensacion,
                CASE
                    WHEN @EffectiveCopayTotal <= 0.00 OR @EffectiveCopayTotal <= cw.PriorCapacity THEN 0.00
                    WHEN (@EffectiveCopayTotal - cw.PriorCapacity) <= cw.LineInclusiveAmount
                    THEN ROUND(@EffectiveCopayTotal - cw.PriorCapacity, 2)
                    ELSE cw.LineInclusiveAmount
                END AS ValorCuota,
                cw.FechaPrestacion,
                cw.LineFinalidad
            FROM CopayWaterfall cw
        )
        INSERT INTO [dbo].[RipsServicios] (
            RipsGuid, TransactionGuid, ServiceCategory, CodServicio, Cantidad,
            ValorUnitario, ValorTotal, ValorDispensacion, ConceptoRecaudo, ValorCuota, FechaPrestacion,
            DiagnosticoPrincipal, DiagnosticoPrincipalCIE11, NomDiagnosticoPrincipalCIE11,
            DiagnosticoRelacionado1CIE11, NomDiagnosticoRelacionado1CIE11,
            ComplicacionCIE11, NomComplicacionCIE11,
            FinalidadTecnologia, CodigoVIDA
        )
        SELECT
            @RipsGuid,
            fs.TransactionGuid,
            fs.ServiceCategory,
            fs.CodServicio,
            fs.Cantidad,
            fs.ValorUnitario,
            fs.ValorTotal,
            fs.ValorDispensacion,
            CASE WHEN fs.ValorCuota > 0.00 THEN @DefaultConceptoRecaudo ELSE '05' END AS ConceptoRecaudo,
            fs.ValorCuota,
            fs.FechaPrestacion,
            @ResolvedPrincipalDiagnosis,
            @ResolvedPrincipalDiagnosisCIE11,
            @ResolvedNomPrincipalCIE11,
            @ResolvedRelatedDiagnosis1CIE11,
            @ResolvedNomRelated1CIE11,
            @ResolvedComplicationCIE11,
            @ResolvedNomComplicationCIE11,
            fs.LineFinalidad,
            @CodigoVIDA
        FROM FinalServices fs
        ORDER BY fs.FechaPrestacion ASC, fs.TransactionGuid ASC;

        IF @TranCount = 0
            COMMIT TRANSACTION;

        SELECT
            @RipsGuid AS RipsGuid,
            @InvoiceGuid AS InvoiceGuid,
            @InvoiceNumber AS NumFactura;
    END TRY
    BEGIN CATCH
        IF @TranCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @TranCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_COLCreateRipsRecord;

        THROW;
    END CATCH;
END;
GO