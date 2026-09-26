CREATE OR ALTER PROCEDURE dbo.Billing_RunClaimScrubber
    @PatientVisit   NVARCHAR(50),
    @PatientId      NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    -- ==========================================================================================
    -- 1. Resolve Patient Demographics
    -- ==========================================================================================
    DECLARE @PatientSex VARCHAR(20);
    DECLARE @AgeInYears INT;

    SELECT TOP 1
        @PatientSex = ISNULL(PatientSex, 'Indeterminate'),
        -- Calculates exact age accounting for leap years and birth month/day
        @AgeInYears = DATEDIFF(YY, PatientDOB, GETDATE()) - 
                      CASE WHEN DATEADD(YY, DATEDIFF(YY, PatientDOB, GETDATE()), PatientDOB) > GETDATE() THEN 1 ELSE 0 END
    FROM ClinicalGeniusEhr.dbo.PatientTable WITH(NOLOCK)
    WHERE PatientId = @PatientId;

    -- ==========================================================================================
    -- 2. Aggregate Visit Quantities (To check Cant_max across multiple entries)
    -- ==========================================================================================
    -- We use a CTE to sum the quantities of the same CUPS code across the entire visit.
    -- If a nurse charted one supply at 8 AM and another at 2 PM, we must evaluate the total.
    ;WITH VisitAggregates AS (
        SELECT 
            CupsCode,
            SUM(Quantity) AS TotalVisitQuantity
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions WITH(NOLOCK)
        WHERE PatientVisit = @PatientVisit
          AND PatientId = @PatientId
          AND Status = 'Active'
        GROUP BY CupsCode
    ),
    -- ==========================================================================================
    -- 3. Evaluate Compliance Rules
    -- ==========================================================================================
    ScrubberEvaluations AS (
        SELECT 
            pt.TransactionId,         -- Unique ID to map back to the UI grid
            pt.TransactionType,       -- Surgery, Supplies, Diagnostics, etc.
            pt.CupsCode,
            c.CUPSName AS ItemDescription,
            pt.Quantity AS LineQuantity,
            va.TotalVisitQuantity,
            pt.DateTimePerformed,
            
            -- Error 1: Gender Mismatch
            -- (Assuming 'F'/'M' in catalog and 'Female'/'Male' in PatientTable)
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

            -- Error 3: Missing Required Diagnosis (If applicable to your EHR)
            -- Note: Adjust 'ItemSnomedCode' or your specific Dx column as needed
            CASE 
                WHEN c.Dx_requerido = '1' AND pt.ItemSnomedCode IS NULL 
                THEN 'Diagnosis Required: This procedure cannot be billed without an associated ICD-10 code.'
                ELSE NULL 
            END AS DiagnosisError

        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK)
        INNER JOIN VisitAggregates va ON pt.CupsCode = va.CupsCode
        -- Join to the master catalog containing your limiting fields
        INNER JOIN ClinicalGeniusEhr.dbo.CupsDictionary c WITH(NOLOCK) ON pt.CupsCode = c.CUPSCode
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.PatientId = @PatientId
          AND pt.Status = 'Active' 
          -- Only evaluate lines that actually have a COP value to avoid scrubbing zero-dollar bundled items
          AND pt.NetAmount > 0 
    )

    -- ==========================================================================================
    -- 4. Return the Defect Queue to the UI
    -- ==========================================================================================
    SELECT 
        TransactionId,
        TransactionType,
        CupsCode,
        ItemDescription,
        LineQuantity,
        TotalVisitQuantity,
        DateTimePerformed,
        -- Coalesce errors into a single, readable string for the billing clerk
        CONCAT_WS(' | ', GenderError, QuantityError, DiagnosisError) AS ScrubberViolationMessage
    FROM ScrubberEvaluations
    WHERE GenderError IS NOT NULL 
       OR QuantityError IS NOT NULL 
       OR DiagnosisError IS NOT NULL
    ORDER BY DateTimePerformed ASC;

END;
GO