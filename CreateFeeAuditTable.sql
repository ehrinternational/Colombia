-- 1. Create the append-only Audit Ledger
CREATE TABLE FeeManagementAudits (
    AuditId NVARCHAR(50) PRIMARY KEY,
    
    -- Must match the data type of PatientTransactions.TransactionGuid
    TransactionGuid NVARCHAR(50) NOT NULL, 
    
    -- Audit Metadata
    ActionTimestamp DATETIME CONSTRAINT DF_FeeManagementAudits_Time DEFAULT GETDATE() NOT NULL,
    ActionByUser NVARCHAR(100) NOT NULL,
    ActionType NVARCHAR(50) NOT NULL, -- e.g., 'Status Change', 'Price Override', 'Pre-Glosa Hold'
    
    -- State Changes
    OldWorkflowStatus NVARCHAR(50) NULL,
    NewWorkflowStatus NVARCHAR(50) NULL,
    
    -- Financial Adjustments
    OldAmount DECIMAL(18, 4) NULL,
    NewAmount DECIMAL(18, 4) NULL,
    
    -- Justifications & Routing
    ReasonCode NVARCHAR(100) NULL,
    InternalNotes NVARCHAR(MAX) NULL,

);
GO