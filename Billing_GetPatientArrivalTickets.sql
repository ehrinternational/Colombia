USE [ClinicalGeniusSupplyChain]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[GetPatientArrivalTickets]
    @DepartmentGuid UNIQUEIDENTIFIER = NULL,
    @QueueStatus    VARCHAR(20)      = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Translate the internal EMR DepartmentGuid to the external TicketId
    DECLARE @MappedTicketId NVARCHAR(50);
    
    IF @DepartmentGuid IS NOT NULL
    BEGIN
        SELECT TOP 1 @MappedTicketId = TicketId 
        FROM [dbo].[Departments] WITH(NOLOCK)
        WHERE DepartmentGuid = @DepartmentGuid;
    END

    -- 2. Query the arrival tickets matching the external TicketId
    SELECT 
        t.TicketGuid,
        t.TicketNumber,
        ISNULL(match.PatientId, '') AS PatientId,
        @DepartmentGuid AS DepartmentGuid,  -- Mapped back for UI context consistency
        t.TicketId,                         -- The external queue routing ID
        t.DocumentType,
        t.DocumentNumber,
        t.FirstName,
        t.MiddleName,
        t.FirstLastName,
        t.SecondLastName,
        t.DateOfBirth,
        t.BiologicalSex,
        t.BloodType,
        t.RhFactor,
        t.DocumentIssueDate,
        t.DocumentExpirationDate,
        t.Nationality,
        t.KioskDeviceId,
        t.QueueStatus,
        t.ArrivalDateTime,
        t.DateTimeEntered,
        t.EnteredBy,
        t.LastUpdatedBy,
        t.DateTimeLastUpdated
    FROM [dbo].[PatientArrivalTickets] t WITH(NOLOCK)
    OUTER APPLY (
        SELECT TOP 1 
            COALESCE(pat.RecordUniqueId, pat.PatientId) AS PatientId
        FROM (
            -- Priority 1: Match by Document Type and Number
            SELECT TOP 1 p.RecordUniqueId, p.PatientId, 1 AS PriorityRank
            FROM [dbo].[PatientTable] p WITH(NOLOCK)
            WHERE p.PrimaryIdNumber = t.DocumentType
              AND p.PtSSN = t.DocumentNumber
              AND t.DocumentNumber IS NOT NULL

            UNION ALL

            -- Priority 2: Fallback match by Demographics
            SELECT TOP 1 p.RecordUniqueId, p.PatientId, 2 AS PriorityRank
            FROM [dbo].[PatientTable] p WITH(NOLOCK)
            WHERE p.PatientDOB = t.DateOfBirth
              AND p.PatientFirstName = t.FirstName
              AND p.MiddleName = t.FirstLastName
              AND p.LastName = t.SecondLastName
              AND t.DateOfBirth IS NOT NULL
        ) pat
        ORDER BY pat.PriorityRank ASC
    ) match
    -- Filter on the resolved TicketId instead of the internal DepartmentGuid
    WHERE (@MappedTicketId IS NULL OR t.TicketId = @MappedTicketId)
      AND (@QueueStatus IS NULL OR t.QueueStatus = @QueueStatus)
    ORDER BY t.ArrivalDateTime ASC;
END;
GO