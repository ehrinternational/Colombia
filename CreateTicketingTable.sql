-- ==========================================================================================
-- KIOSK & PATIENT ARRIVAL QUEUE TICKETING SCHEMA
-- TARGET ARCHITECTURE: SQL Server 2014+ / Azure SQL Database (Deploy to EHR Database)
-- ==========================================================================================

CREATE TABLE [dbo].[PatientArrivalTickets] (
    -- Primary Key, Session & Routing Links
    [TicketGuid] UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_PatientArrivalTickets_TicketGuid] DEFAULT NEWID(),
    [TicketId] NVARCHAR(50) NULL,                    -- External kiosk/session identifier for EMR grid mapping
    [FacilityId] NVARCHAR(50) NULL,                  -- Multi-facility separation boundary
    [TicketNumber] NVARCHAR(20) NOT NULL,            -- e.g., "URG-045" for waiting room display
    [PatientId] NVARCHAR(50) NULL,                   -- Links to PatientTable.RecordUniqueId (NULL if new patient)
    [PatientVisit] NVARCHAR(50) NULL,                -- Links to PatientVisits.PatientVisitUniqueId once triage/admission starts
    [DepartmentGuid] UNIQUEIDENTIFIER NULL,          -- Routes the ticket to a specific clinical queue/desk (Matches Departments PK)

    -- Document Data (MRZ / PDF417 Scans)
    [DocumentType] VARCHAR(10) NOT NULL,             -- CC, CE, TI, PA, PEP, PPT
    [DocumentNumber] NVARCHAR(50) NOT NULL,
    [FirstName] NVARCHAR(100) NULL,
    [MiddleName] NVARCHAR(100) NULL,
    [FirstLastName] NVARCHAR(100) NULL,
    [SecondLastName] NVARCHAR(100) NULL,
    [DateOfBirth] DATE NULL,
    [BiologicalSex] VARCHAR(20) NULL,

    -- Clinical Indicators (Extracted specifically from Colombian IDs)
    [BloodType] VARCHAR(5) NULL,                     -- A, B, AB, O
    [RhFactor] VARCHAR(5) NULL,                      -- Positivo (+), Negativo (-)

    -- Expiration & Sovereignty (Primarily for Passports / CE / PEP / PPT)
    [DocumentIssueDate] DATE NULL,
    [DocumentExpirationDate] DATE NULL,
    [Nationality] NVARCHAR(50) NULL,

    -- Ticketing Workflow & Device Tracking
    [KioskDeviceId] NVARCHAR(50) NULL,               -- Identifies the specific hardware scanner
    [QueueStatus] VARCHAR(20) NOT NULL CONSTRAINT [DF_PatientArrivalTickets_QueueStatus] DEFAULT 'Waiting', -- 'Waiting', 'InTriage', 'Admitted', 'Canceled'

    -- Standard Audit Fields
    [ArrivalDateTime] DATETIME NOT NULL CONSTRAINT [DF_PatientArrivalTickets_ArrivalDateTime] DEFAULT GETDATE(),
    [DateTimeEntered] DATETIME NOT NULL CONSTRAINT [DF_PatientArrivalTickets_DateTimeEntered] DEFAULT GETDATE(),
    [EnteredBy] NVARCHAR(100) NULL,                  -- e.g., 'TurnoCareAPI'
    [LastUpdatedBy] NVARCHAR(100) NULL,
    [DateTimeLastUpdated] DATETIME NULL,

    CONSTRAINT [PK_PatientArrivalTickets] PRIMARY KEY CLUSTERED ([TicketGuid])
);
GO

-- Operational Queue & Patient Matching Indices
CREATE NONCLUSTERED INDEX [IX_PatientArrivalTickets_Queue]
    ON [dbo].[PatientArrivalTickets] ([QueueStatus], [DepartmentGuid], [ArrivalDateTime]);

CREATE NONCLUSTERED INDEX [IX_PatientArrivalTickets_Document]
    ON [dbo].[PatientArrivalTickets] ([DocumentNumber], [DocumentType]);

CREATE NONCLUSTERED INDEX [IX_PatientArrivalTickets_PatientVisit]
    ON [dbo].[PatientArrivalTickets] ([PatientVisit])
    WHERE [PatientVisit] IS NOT NULL;
GO
