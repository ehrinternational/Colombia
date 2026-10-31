-- ==============================================================================
-- Procedure: GetFeeManagementAudits
-- Purpose: Retrieves the deterministic ledger history for a specific transaction.
-- ==============================================================================
CREATE PROCEDURE GetFeeManagementAudits
    @TransactionGuid NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    SET @TransactionGuid = LTRIM(RTRIM(@TransactionGuid));

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
    ORDER BY ActionTimestamp DESC, AuditId DESC;

END;
GO