-- ==============================================================================
-- Procedure: InsertFeeManagementAudit
-- Purpose: Appends to the audit ledger and updates PatientTransactions 
--          with recalculated TaxAmount and NetAmount.
-- ==============================================================================
CREATE PROCEDURE InsertFeeManagementAudit
    @TransactionGuid NVARCHAR(50),
    @ActionType NVARCHAR(50),
    @OldWorkflowStatus NVARCHAR(50),
    @NewWorkflowStatus NVARCHAR(50),
    @OldAmount DECIMAL(18, 4),
    @NewAmount DECIMAL(18, 4),
    @ReasonCode NVARCHAR(100) = NULL,
    @InternalNotes NVARCHAR(MAX) = NULL,
    @UserName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AuditId NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50));

    INSERT INTO FeeManagementAudits (
        AuditId, 
        TransactionGuid, 
        ActionTimestamp, 
        ActionByUser, 
        ActionType, 
        OldWorkflowStatus, 
        NewWorkflowStatus, 
        OldAmount, 
        NewAmount, 
        ReasonCode, 
        InternalNotes
    )
    VALUES (
        @AuditId, 
        @TransactionGuid, 
        GETDATE(), 
        @UserName, 
        @ActionType, 
        @OldWorkflowStatus, 
        @NewWorkflowStatus, 
        @OldAmount, 
        @NewAmount, 
        @ReasonCode, 
        @InternalNotes
    );

    IF @NewWorkflowStatus = 'Rejected'
    BEGIN
        UPDATE PatientTransactions
        SET 
            CurrentWorkflowStatus = @NewWorkflowStatus,
            PerItemChargeAmount = 0.00,
            TaxAmount = 0.00,
            NetAmount = 0.00
        WHERE TransactionGuid = @TransactionGuid;
    END
    ELSE
    BEGIN
        UPDATE PatientTransactions
        SET 
            CurrentWorkflowStatus = @NewWorkflowStatus,
            PerItemChargeAmount = @NewAmount,
            TaxAmount = CASE 
                WHEN ISNULL(TaxRate, 0) > 0 THEN (TransactionQuantity * @NewAmount) * TaxRate 
                ELSE 0 
            END,
            NetAmount = (TransactionQuantity * @NewAmount) + 
                CASE 
                    WHEN ISNULL(TaxRate, 0) > 0 THEN (TransactionQuantity * @NewAmount) * TaxRate 
                    ELSE 0 
                END
        WHERE TransactionGuid = @TransactionGuid;
    END

END;
GO