USE [ClinicalGeniusSupplyChain]
GO

/****** Object:  COLInvoiceScrubber ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE {odata}.{COLInvoiceScrubber}
    @PatientVisit    NVARCHAR(50),
    @FacilityId      NVARCHAR(50),
    @TargetClaimGuid NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    -- ==========================================================================================
    -- 1. Resolve Patient Demographics & PatientId
    -- ==========================================================================================
    DECLARE @PatientSex VARCHAR(20);
    DECLARE @AgeInYears INT;
    DECLARE @PatientId  NVARCHAR(50);
    SELECT TOP 1 @PatientId = PatientId
    FROM ClinicalGeniusEhr.dbo.PatientVisits WITH(NOLOCK)
    WHERE PatientVisitUniqueId = @PatientVisit AND FacilityId = @FacilityId;

    SELECT TOP 1
        @PatientSex = ISNULL(PatientSex, 'Indeterminate'),
        -- Calculates exact age accounting for leap years and birth month/day
        @AgeInYears = DATEDIFF(YY, PatientDOB, GETDATE()) - 
                      CASE WHEN DATEADD(YY, DATEDIFF(YY, PatientDOB, GETDATE()), PatientDOB) > GETDATE() THEN 1 ELSE 0 END
    FROM ClinicalGeniusEhr.dbo.PatientTable WITH(NOLOCK)
    WHERE PatientId = @PatientId;

    -- ==========================================================================================
    -- 2. Aggregate Visit Quantities (Filtered by Target Scope)
    -- ==========================================================================================
    ;WITH VisitAggregates AS (
        SELECT 
            CupsCode,
            SUM(TransactionQuantity) AS TotalVisitQuantity
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(NOLOCK)
        WHERE PatientVisit = @PatientVisit
          AND Facility = @FacilityId
          AND Status = 'Active'
          AND (
              (@TargetClaimGuid = 'Patient' AND ClaimGuid IS NULL) OR
              (@TargetClaimGuid <> 'Patient' AND ClaimGuid = @TargetClaimGuid)
          )
        GROUP BY CupsCode
    ),
    -- ==========================================================================================
    -- 3. Evaluate Compliance Rules
    -- ==========================================================================================
    ScrubberEvaluations AS (
        SELECT 
            pt.TransactionType,       -- Surgery, Supplies, Diagnostics, etc.
            pt.CupsCode,
            c.CUPSName AS ItemDescription,
            pt.TransactionQuantity AS LineQuantity,
            va.TotalVisitQuantity,
            pt.DateTimeEntered,
            
            -- Error 1: Gender Mismatch
            CASE 
                WHEN c.Sexo = 'F' AND @PatientSex = 'Male' THEN 'Gender Mismatch: Female-only procedure billed for a Male patient.'
                WHEN c.Sexo = 'M' AND @PatientSex = 'Female' THEN 'Gender Mismatch: Male-only procedure billed for a Female patient.'
                ELSE NULL 
            END AS GenderError,

            -- Error 2: Quantity Limit Exceeded
            CASE 
                WHEN CAST(c.Cant_max AS INT) > 0 AND va.TotalVisitQuantity > CAST(c.Cant_max AS INT) 
                THEN CONCAT('Quantity Limit Exceeded: Billed ', va.TotalVisitQuantity, ', but maximum allowed per visit is ', c.Cant_max, '.')
                ELSE NULL 
            END AS QuantityError,

            -- Error 3: Missing Required Diagnosis
            CASE 
                WHEN c.Dx_requerido = '1' AND pt.ItemSnomedCode IS NULL 
                THEN 'Diagnosis Required: This procedure cannot be billed without an associated ICD-10 code.'
                ELSE NULL 
            END AS DiagnosisError

        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK)
        INNER JOIN VisitAggregates va ON pt.CupsCode = va.CupsCode
        INNER JOIN ClinicalGeniusSupplyChain.dbo.Cups c WITH(NOLOCK) ON pt.CupsCode = c.CUPSCode
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Facility = @FacilityId
          AND pt.Status = 'Active' 
          AND pt.Status <> 'Unbillable'
          AND (
              (@TargetClaimGuid = 'Patient' AND pt.ClaimGuid IS NULL) OR
              (@TargetClaimGuid <> 'Patient' AND pt.ClaimGuid = @TargetClaimGuid)
          )
    )

    -- ==========================================================================================
    -- 4. Return the Defect Queue to the UI
    -- ==========================================================================================
    SELECT 
        TransactionType,
        CupsCode,
        ItemDescription,
        LineQuantity,
        TotalVisitQuantity,
        DateTimeEntered,
        CONCAT_WS(' | ', GenderError, QuantityError, DiagnosisError) AS ScrubberViolationMessage
    FROM ScrubberEvaluations
    WHERE GenderError IS NOT NULL 
       OR QuantityError IS NOT NULL 
       OR DiagnosisError IS NOT NULL
    ORDER BY DateTimeEntered ASC;

END;
GO