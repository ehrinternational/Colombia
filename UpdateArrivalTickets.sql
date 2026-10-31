SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'[dbo].[UpdateArrivalTicketStatus]', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE [dbo].[UpdateArrivalTicketStatus] AS BEGIN SET NOCOUNT ON; END');
GO

-- ==============================================================================
-- Procedure: [dbo].[UpdateArrivalTicketStatus]
-- Purpose: Atomically updates arrival ticket queue status and links or preserves
--          PatientVisit and PatientId without erasing prior values.
-- ==============================================================================
ALTER PROCEDURE [dbo].[UpdateArrivalTicketStatus]
    @TicketGuid   UNIQUEIDENTIFIER,
    @QueueStatus  VARCHAR(20),
    @UpdatedBy    NVARCHAR(100),
    @PatientVisit NVARCHAR(50) = NULL,
    @PatientId    NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @QueueStatus = LTRIM(RTRIM(@QueueStatus));
    SET @UpdatedBy = LTRIM(RTRIM(@UpdatedBy));
    SET @PatientVisit = NULLIF(LTRIM(RTRIM(@PatientVisit)), N'');
    SET @PatientId = NULLIF(LTRIM(RTRIM(@PatientId)), N'');

    IF @TicketGuid IS NULL
        THROW 50001, N'@TicketGuid is required.', 1;

    IF NULLIF(@QueueStatus, '') IS NULL
        THROW 50002, N'@QueueStatus is required.', 1;

    IF NULLIF(@UpdatedBy, N'') IS NULL
        THROW 50003, N'@UpdatedBy is required.', 1;

    DECLARE @TranCount INT = @@TRANCOUNT;

    BEGIN TRY
        IF @TranCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION sp_UpdateArrivalTicketStatus;

        UPDATE [dbo].[PatientArrivalTickets] WITH (UPDLOCK, ROWLOCK)
        SET 
            QueueStatus = @QueueStatus,
            PatientVisit = COALESCE(@PatientVisit, PatientVisit),
            PatientId = COALESCE(@PatientId, PatientId),
            LastUpdatedBy = @UpdatedBy,
            DateTimeLastUpdated = SYSDATETIME()
        WHERE TicketGuid = @TicketGuid;

        IF @@ROWCOUNT = 0
        BEGIN
            DECLARE @NotFoundMsg NVARCHAR(200) = N'TicketGuid "' + CAST(@TicketGuid AS NVARCHAR(36)) + N'" was not found in PatientArrivalTickets.';
            THROW 50004, @NotFoundMsg, 1;
        END

        IF @TranCount = 0
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @TranCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @TranCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_UpdateArrivalTicketStatus;

        THROW;
    END CATCH;
END;
GO