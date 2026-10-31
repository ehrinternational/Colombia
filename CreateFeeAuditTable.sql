-- ==========================================================================================
-- FEE MANAGEMENT & PRE-GLOSA AUDIT LEDGER SCHEMA
-- TARGET ARCHITECTURE: SQL Server 2014+ / Azure SQL Database
-- ==========================================================================================

CREATE TABLE dbo.FeeManagementAudits (
    AuditId NVARCHAR(50) NOT NULL CONSTRAINT DF_FeeManagementAudits_AuditId DEFAULT NEWID(),

    -- Must match the data type of PatientTransactions.TransactionGuid
    TransactionGuid NVARCHAR(50) NOT NULL,

    -- Audit Metadata
    ActionTimestamp DATETIME NOT NULL CONSTRAINT DF_FeeManagementAudits_Time DEFAULT GETDATE(),
    ActionByUser NVARCHAR(100) NOT NULL,
    ActionType NVARCHAR(50) NOT NULL, -- e.g., 'Status Change', 'Price Override', 'Pre-Glosa Hold'

    -- State Changes
    OldWorkflowStatus NVARCHAR(50) NULL,
    NewWorkflowStatus NVARCHAR(50) NULL,

    -- Financial Adjustments (Matches PatientTransactions 4-decimal item precision)
    OldAmount DECIMAL(18, 4) NULL,
    NewAmount DECIMAL(18, 4) NULL,

    -- Justifications & Routing
    ReasonCode NVARCHAR(100) NULL,
    InternalNotes NVARCHAR(MAX) NULL,

    CONSTRAINT PK_FeeManagementAudits PRIMARY KEY CLUSTERED (AuditId)
);
GO

CREATE NONCLUSTERED INDEX IX_FeeManagementAudits_TransactionGuid
    ON dbo.FeeManagementAudits (TransactionGuid, ActionTimestamp DESC);
GO
