USE [ClinicalGeniusSupplyChain]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[UpdateArrivalTicketStatus]
    @TicketGuid   UNIQUEIDENTIFIER,
    @QueueStatus  VARCHAR(20),
    @UpdatedBy    NVARCHAR(100),
    @PatientVisit NVARCHAR(50) = NULL,
    @PatientId    NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE [dbo].[PatientArrivalTickets] WITH(ROWLOCK)
        SET 
            QueueStatus = @QueueStatus,
            -- COALESCE ensures existing links are not erased if parameters are omitted during a cancellation
            PatientVisit = COALESCE(@PatientVisit, PatientVisit),
            PatientId = COALESCE(@PatientId, PatientId),
            LastUpdatedBy = @UpdatedBy,
            DateTimeLastUpdated = GETDATE()
        WHERE TicketGuid = @TicketGuid;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrorSeverity INT = ERROR_SEVERITY(),
                @ErrorState INT = ERROR_STATE();
                
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH;
END;
GO