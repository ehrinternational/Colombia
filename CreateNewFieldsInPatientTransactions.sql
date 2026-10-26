BEGIN
    ALTER TABLE PatientTransactions
    ADD 
        CurrentWorkflowStatus NVARCHAR(50) DEFAULT 'Pending Review' NULL,
        DIANInvoiceBatchId NVARCHAR(50) NULL,
        RIPSBatchId NVARCHAR(50) NULL;
END
GO