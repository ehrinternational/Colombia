-- ==============================================================================
-- Procedure: GetFeeManagementAudits
-- Purpose: Retrieves the ledger history for a specific transaction.
-- ==============================================================================
CREATE PROCEDURE GetFeeManagementAudits
    @TransactionGuid NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT 
        AuditId, 
        ActionTimestamp, 
        ActionByUser, 
        ActionType, 
        OldWorkflowStatus, 
        NewWorkflowStatus, 
        OldAmount, 
        NewAmount, 
        ReasonCode, 
        InternalNotes
    FROM FeeManagementAudits
    WHERE TransactionGuid = @TransactionGuid
    ORDER BY ActionTimestamp DESC;

END;
GO