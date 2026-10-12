USE [ClinicalGeniusSupplyChain]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[COLInsertGlosa]
    @FacilityId             NVARCHAR(50),
    @UserId                 NVARCHAR(100),
    @CreationSource         VARCHAR(30),
    @InvoiceGuid            NVARCHAR(50),
    @PayerGlosaReference    NVARCHAR(100),
    @RadicationDate         DATE,
    @TotalDisputedAmount    DECIMAL(18,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @GlosaGuid NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50));
    DECLARE @ResponseDeadline DATE = @RadicationDate;
    DECLARE @BusinessDaysAdded INT = 0;

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
        ('2026-08-17'),('2026-10-12'),('2026-11-02'),('2026-11-16'),('2026-12-08'),('2026-12-25'),
        ('2027-01-01'),('2027-01-11'),('2027-03-22'),('2027-03-25'),('2027-03-26'),('2027-05-01'),
        ('2027-05-17'),('2027-06-07'),('2027-06-14'),('2027-07-05'),('2027-07-20'),('2027-08-07'),
        ('2027-08-16'),('2027-10-18'),('2027-11-01'),('2027-11-15'),('2027-12-08'),('2027-12-25');

    -- 2. Calculate statutory 15-business-day response deadline
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
        BEGIN TRAN;

        -- 3. Insert Glosa Header
        INSERT INTO ClinicalGeniusSupplyChain.dbo.InvoiceGlosas (
            FacilityId, GlosaGuid, InvoiceGuid, PayerGlosaReference, 
            RadicationDate, ResponseDeadlineDate, TotalDisputedAmount, 
            TotalAcceptedAmount, TotalDefendedAmount, Status, 
            CreationSource, DateTimeEntered, LastUpdatedBy
        )
        VALUES (
            @FacilityId, @GlosaGuid, @InvoiceGuid, @PayerGlosaReference,
            @RadicationDate, @ResponseDeadline, ISNULL(@TotalDisputedAmount, 0.00),
            0.00, 0.00, 'Radicada',
            @CreationSource, GETDATE(), @UserId
        );

        -- Return the newly generated Guid to the UI
        SELECT @GlosaGuid AS GlosaGuid;

        COMMIT TRAN;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrSeverity INT = ERROR_SEVERITY(),
                @ErrState INT = ERROR_STATE();

        RAISERROR(@ErrMsg, @ErrSeverity, @ErrState);
    END CATCH;

    IF OBJECT_ID('tempdb..#Holidays') IS NOT NULL DROP TABLE #Holidays;
END;
GO