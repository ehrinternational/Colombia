SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'[dbo].[GetPatientArrivalTickets]', N'P') IS NULL
    EXEC(N'CREATE PROCEDURE [dbo].[GetPatientArrivalTickets] AS BEGIN SET NOCOUNT ON; END');
GO

-- ==============================================================================
-- Procedure: [dbo].[GetPatientArrivalTickets]
-- Purpose: Retrieves arrival tickets filtered by mapped department routing ID
--          and queue status, resolving linked or matched PatientTable records.
-- ==============================================================================
ALTER PROCEDURE [dbo].[GetPatientArrivalTickets]
    @DepartmentGuid UNIQUEIDENTIFIER = NULL,
    @QueueStatus    VARCHAR(20)      = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @QueueStatus = NULLIF(LTRIM(RTRIM(@QueueStatus)), '');

    SELECT 
        t.TicketGuid,
        t.TicketNumber,
        COALESCE(
            NULLIF(LTRIM(RTRIM(t.PatientId)), N''),
            matchDoc.MatchedPatientId,
            matchDemo.MatchedPatientId,
            N''
        ) AS PatientId,
        COALESCE(@DepartmentGuid, dept.DepartmentGuid) AS DepartmentGuid,
        t.TicketId,
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
        t.DateTimeLastUpdated,
        ISNULL(t.PatientVisit, N'') AS PatientVisit
    FROM [dbo].[PatientArrivalTickets] t
    OUTER APPLY (
        SELECT TOP (1)
            d.DepartmentGuid
        FROM [dbo].[Departments] d
        WHERE @DepartmentGuid IS NULL
          AND NULLIF(LTRIM(RTRIM(t.TicketId)), '') IS NOT NULL
          AND d.TicketId = t.TicketId
        ORDER BY d.DepartmentGuid ASC
    ) dept
    OUTER APPLY (
        -- Priority 1: Match by Document Type and Number when ticket is not yet linked
        SELECT TOP (1)
            COALESCE(
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), p.RecordUniqueId))), N''),
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), p.PatientId))), N'')
            ) AS MatchedPatientId
        FROM [dbo].[PatientTable] p
        WHERE NULLIF(LTRIM(RTRIM(t.PatientId)), N'') IS NULL
          AND NULLIF(LTRIM(RTRIM(t.DocumentType)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(t.DocumentNumber)), '') IS NOT NULL
          AND p.PrimaryIdNumber = t.DocumentType
          AND p.PtSSN = t.DocumentNumber
        ORDER BY p.RecordUniqueId DESC, p.PatientId DESC
    ) matchDoc
    OUTER APPLY (
        -- Priority 2: Fallback match by Demographics only if Priority 1 found no match
        SELECT TOP (1)
            COALESCE(
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), p.RecordUniqueId))), N''),
                NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(50), p.PatientId))), N'')
            ) AS MatchedPatientId
        FROM [dbo].[PatientTable] p
        WHERE NULLIF(LTRIM(RTRIM(t.PatientId)), N'') IS NULL
          AND matchDoc.MatchedPatientId IS NULL
          AND t.DateOfBirth IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(t.FirstName)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(t.FirstLastName)), '') IS NOT NULL
          AND p.PatientDOB = t.DateOfBirth
          AND (
              p.PatientFirstName = t.FirstName
              OR (
                  NULLIF(LTRIM(RTRIM(t.MiddleName)), '') IS NOT NULL
                  AND LTRIM(RTRIM(p.PatientFirstName)) = LTRIM(RTRIM(t.FirstName)) + N' ' + LTRIM(RTRIM(t.MiddleName))
              )
          )
          AND p.MiddleName = t.FirstLastName
          AND (
              p.LastName = t.SecondLastName
              OR (
                  NULLIF(LTRIM(RTRIM(p.LastName)), '') IS NULL
                  AND NULLIF(LTRIM(RTRIM(t.SecondLastName)), '') IS NULL
              )
          )
        ORDER BY p.RecordUniqueId DESC, p.PatientId DESC
    ) matchDemo
    WHERE (
        @DepartmentGuid IS NULL
        OR EXISTS (
            SELECT 1
            FROM [dbo].[Departments] d_filter
            WHERE d_filter.DepartmentGuid = @DepartmentGuid
              AND NULLIF(LTRIM(RTRIM(d_filter.TicketId)), '') IS NOT NULL
              AND t.TicketId = d_filter.TicketId
        )
    )
      AND (@QueueStatus IS NULL OR t.QueueStatus = @QueueStatus)
    ORDER BY t.ArrivalDateTime ASC, t.TicketGuid ASC
    OPTION (RECOMPILE);
END;
GO