USE [ClinicalGeniusSupplyChain]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [odata].[COLCreateGlosa]
    @FacilityId             NVARCHAR(50),
    @InvoiceNumber          NVARCHAR(20),
    @PayerGlosaReference    NVARCHAR(100),
    @RadicationDate         DATE,
    @UserId                 NVARCHAR(100),
    @LinesXml               XML -- Batch payload of disputed lines
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @InvoiceGuid        NVARCHAR(50);
    DECLARE @GlosaGuid          NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50));
    DECLARE @ResponseDeadline   DATE = @RadicationDate;
    DECLARE @BusinessDaysAdded  INT = 0;
    DECLARE @CalculatedDisputed DECIMAL(18,2) = 0.00;

    -- Pre-load temporary table for legal holiday exclusions
    IF OBJECT_ID('tempdb..#Holidays') IS NOT NULL DROP TABLE #Holidays;
    CREATE TABLE #Holidays (HolidayDate DATE PRIMARY KEY CLUSTERED);

    INSERT INTO #Holidays (HolidayDate)
    VALUES
        ('2024-01-01'),('2024-01-08'),('2024-03-25'),('2024-03-28'),('2024-03-29'),('2024-05-01'),
        ('2024-05-13'),('2024-06-03'),('2024-06-10'),('2024-07-01'),('2024-07-20'),('2024-08-07'),
        ('2024-08-19'),('2024-10-14'),('2024-11-04'),('2024-11-11'),('2024-12-08'),('2024-12-25'),
        ('2025-01-01'),('2025-01-13'),('2025-03-24'),('2025-04-17'),('2025-04-18'),('2025-05-01'),
        ('2025-06-02'),('2025-06-23'),('2025-06-30'),('2025-07-20'),('2025-08-07'),('2025-08-18'),
        ('2025-10-13'),('2025-11-03'),('2025-11-16'),('2025-12-08'),('2025-12-25'),
        ('2026-01-01'),('2026-01-12'),('2026-03-23'),('2026-04-02'),('2026-04-03'),('2026-05-01'),
        ('2026-05-18'),('2026-06-08'),('2026-06-15'),('2026-06-29'),('2026-07-20'),('2026-08-07'),
        ('2026-08-17'),('2026-10-12'),('2026-11-02'),('2026-11-16'),('2026-12-08'),('2026-12-25');

    -- 1. Locate the DIAN Invoice Header
    SELECT TOP 1 @InvoiceGuid = InvoiceGuid 
    FROM ClinicalGeniusSupplyChain.DianInvoices WITH(NOLOCK)
    WHERE InvoiceNumber = @InvoiceNumber 
      AND FacilityId = @FacilityId;

    IF @InvoiceGuid IS NULL
    BEGIN
        RAISERROR('InvoiceNumber not found in DIAN Ledger.', 16, 1);
        RETURN;
    END;

    -- 2. Calculate statutory 15-business-day response deadline (excluding weekends & holidays)
    WHILE @BusinessDaysAdded < 15
    BEGIN
        SET @ResponseDeadline = DATEADD(DAY, 1, @ResponseDeadline);
        IF DATENAME(WEEKDAY, @ResponseDeadline) NOT IN ('Saturday', 'Sunday')
           AND NOT EXISTS (SELECT 1 FROM #Holidays WHERE HolidayDate = @ResponseDeadline)
        BEGIN
            SET @BusinessDaysAdded = @BusinessDaysAdded + 1;
        END
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 3. Parse incoming XML lines into a staging table
        IF OBJECT_ID('tempdb..#ParsedGlosaLines') IS NOT NULL DROP TABLE #ParsedGlosaLines;
        CREATE TABLE #ParsedGlosaLines (
            LineNumber INT,
            GeneralGlosaCode VARCHAR(2),
            SpecificGlosaCode VARCHAR(3),
            DisputedAmount DECIMAL(18,2),
            PayerObservation NVARCHAR(MAX)
        );

        INSERT INTO #ParsedGlosaLines (LineNumber, GeneralGlosaCode, SpecificGlosaCode, DisputedAmount, PayerObservation)
        SELECT 
            T.c.value('(LineNumber)[1]', 'INT'),
            T.c.value('(GeneralGlosaCode)[1]', 'VARCHAR(2)'),
            T.c.value('(SpecificGlosaCode)[1]', 'VARCHAR(3)'),
            T.c.value('(DisputedAmount)[1]', 'DECIMAL(18,2)'),
            T.c.value('(PayerObservation)[1]', 'NVARCHAR(MAX)')
        FROM @LinesXml.nodes('/Lines/Line') T(c);

        -- 4. Calculate total disputed amount directly from lines
        SELECT @CalculatedDisputed = ISNULL(SUM(DisputedAmount), 0.00)
        FROM #ParsedGlosaLines;

        -- 5. Insert Glosa Header
        INSERT INTO ClinicalGeniusSupplyChain.InvoiceGlosas (
            FacilityId, GlosaGuid, InvoiceGuid, PayerGlosaReference, 
            RadicationDate, ResponseDeadlineDate, TotalDisputedAmount, 
            TotalAcceptedAmount, TotalDefendedAmount, Status, 
            DateTimeEntered, LastUpdatedBy
        )
        VALUES (
            @FacilityId, @GlosaGuid, @InvoiceGuid, @PayerGlosaReference,
            @RadicationDate, @ResponseDeadline, @CalculatedDisputed,
            0.00, 0.00, 'Radicada',
            GETDATE(), @UserId
        );

        -- 6. Insert Glosa Detail Lines (Mapping to DianInvoiceLines AND PatientTransactions)
        INSERT INTO ClinicalGeniusSupplyChain.InvoiceGlosaLines (
            GlosaGuid, InvoiceLineGuid, TransactionGuid, 
            GeneralGlosaCode, SpecificGlosaCode, DisputedAmount, 
            AcceptedAmount, DefendedAmount, PayerObservation, LineStatus
        )
        SELECT 
            @GlosaGuid,
            dil.InvoiceLineGuid,
            dil.TransactionGuid,
            pgl.GeneralGlosaCode,
            pgl.SpecificGlosaCode,
            -- Cap dispute at line net amount to prevent negative balances
            CASE WHEN pgl.DisputedAmount > dil.LineNetAmount THEN dil.LineNetAmount ELSE pgl.DisputedAmount END,
            0.00,
            0.00,
            pgl.PayerObservation,
            'Pending'
        FROM #ParsedGlosaLines pgl
        INNER JOIN ClinicalGeniusSupplyChain.DianInvoiceLines dil WITH(NOLOCK)
            ON dil.InvoiceGuid = @InvoiceGuid 
           AND dil.LineNumber = pgl.LineNumber;

        COMMIT TRANSACTION;

        -- 7. Return summary confirmation to the calling service
        SELECT 
            @GlosaGuid AS GlosaGuid,
            @ResponseDeadline AS ResponseDeadlineDate,
            @CalculatedDisputed AS TotalDisputedAmount,
            (SELECT COUNT(*) FROM #ParsedGlosaLines) AS TotalLinesRecorded;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrSeverity INT = ERROR_SEVERITY(),
                @ErrState INT = ERROR_STATE();

        RAISERROR(@ErrMsg, @ErrSeverity, @ErrState);
    END CATCH;

    IF OBJECT_ID('tempdb..#Holidays') IS NOT NULL DROP TABLE #Holidays;
    IF OBJECT_ID('tempdb..#ParsedGlosaLines') IS NOT NULL DROP TABLE #ParsedGlosaLines;
END;
GO