USE [ClinicalGeniusSupplyChain]
GO

CREATE TABLE [dbo].[PatientArrivalTickets] (
    -- Primary Key & Linking
    [TicketGuid] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    [TicketNumber] NVARCHAR(20) NOT NULL,            -- e.g., "URG-045" for the waiting room display
    [PatientId] NVARCHAR(50) NULL,                   -- Links to PatientTable.RecordUniqueId (NULL if new patient)
    [PatientVisit] NVARCHAR(50) NULL,                -- Links to PatientVisits.PatientVisitUniqueId once triage/admission starts
    [DepartmentGuid] UNIQUEIDENTIFIER NULL,          -- Routes the ticket to a specific clinical queue/desk

    -- Document Data (MRZ / PDF417 Scans)
    [DocumentType] VARCHAR(10) NOT NULL,             -- CC (Cédula), CE (Cédula Extranjería), TI (Tarjeta Identidad), PA (Pasaporte), PEP
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
    
    -- Expiration & Sovereignty (Primarily for Passports / CE / PEP)
    [DocumentIssueDate] DATE NULL,
    [DocumentExpirationDate] DATE NULL,
    [Nationality] NVARCHAR(50) NULL,

    -- Ticketing Workflow & Device Tracking
    [KioskDeviceId] NVARCHAR(50) NULL,               -- Identifies the specific hardware scanner
    [QueueStatus] VARCHAR(20) NOT NULL,              -- 'Waiting', 'InTriage', 'Admitted', 'Canceled'
    
    -- Standard Audit Fields
    [ArrivalDateTime] DATETIME NOT NULL DEFAULT GETDATE(),
    [DateTimeEntered] DATETIME NOT NULL DEFAULT GETDATE(),
    [EnteredBy] NVARCHAR(100) NULL,                  -- e.g., 'TurnoCareAPI'
    [LastUpdatedBy] NVARCHAR(100) NULL,
    [DateTimeLastUpdated] DATETIME NULL
);
GO
