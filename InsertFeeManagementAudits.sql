-- ==============================================================================
-- Procedure: InsertFeeManagementAudit
-- Purpose: Atomically locks PatientTransactions, logs authoritative prior state 
--          to FeeManagementAudits, and recalculates TaxAmount and NetAmount.
-- ==============================================================================
CREATE PROCEDURE InsertFeeManagementAudit
    @TransactionGuid NVARCHAR(50),
    @ActionType NVARCHAR(50),
    @NewWorkflowStatus NVARCHAR(50),
    @NewAmount DECIMAL(18, 4),
    @UserName NVARCHAR(100),
    @OldWorkflowStatus NVARCHAR(50) = NULL,
    @OldAmount DECIMAL(18, 4) = NULL,
    @ReasonCode NVARCHAR(100) = NULL,
    @InternalNotes NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @TransactionGuid = LTRIM(RTRIM(@TransactionGuid));
    SET @ActionType = LTRIM(RTRIM(@ActionType));
    SET @NewWorkflowStatus = LTRIM(RTRIM(@NewWorkflowStatus));
    SET @UserName = LTRIM(RTRIM(@UserName));

    IF NULLIF(@TransactionGuid, N'') IS NULL
        THROW 50001, N'@TransactionGuid is required.', 1;

    IF NULLIF(@ActionType, N'') IS NULL
        THROW 50002, N'@ActionType is required.', 1;

    IF NULLIF(@NewWorkflowStatus, N'') IS NULL
        THROW 50003, N'@NewWorkflowStatus is required.', 1;

    IF NULLIF(@UserName, N'') IS NULL
        THROW 50004, N'@UserName is required.', 1;

    IF @NewWorkflowStatus <> N'Rejected' AND @NewAmount IS NULL
        THROW 50005, N'@NewAmount is required when @NewWorkflowStatus is not Rejected.', 1;

    DECLARE @TranCount INT = @@TRANCOUNT;
    DECLARE @AuditId NVARCHAR(50) = CAST(NEWID() AS NVARCHAR(50));

    DECLARE @DbOldWorkflowStatus NVARCHAR(50);
    DECLARE @DbOldAmount DECIMAL(18, 4);
    DECLARE @Quantity DECIMAL(18, 4);
    DECLARE @EffectiveTaxRate DECIMAL(18, 8);

    DECLARE @EffectiveNewAmount DECIMAL(18, 4);
    DECLARE @LineSubtotal DECIMAL(18, 4);
    DECLARE @CalculatedTax DECIMAL(18, 4);
    DECLARE @CalculatedNet DECIMAL(18, 4);

    BEGIN TRY
        IF @TranCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION sp_InsertFeeManagementAudit;

        SELECT 
            @DbOldWorkflowStatus = CurrentWorkflowStatus,
            @DbOldAmount = PerItemChargeAmount,
            @Quantity = ISNULL(TransactionQuantity, 0),
            @EffectiveTaxRate = CASE WHEN ISNULL(TaxRate, 0) > 0 THEN TaxRate ELSE 0 END
        FROM PatientTransactions WITH (UPDLOCK, ROWLOCK)
        WHERE TransactionGuid = @TransactionGuid;

        IF @@ROWCOUNT = 0
        BEGIN
            RAISERROR(N'TransactionGuid "%s" was not found in PatientTransactions.', 16, 1, @TransactionGuid);
        END

        IF @NewWorkflowStatus = N'Rejected'
        BEGIN
            SET @EffectiveNewAmount = 0.0000;
            SET @CalculatedTax = 0.0000;
            SET @CalculatedNet = 0.0000;
        END
        ELSE
        BEGIN
            SET @EffectiveNewAmount = @NewAmount;
            SET @LineSubtotal = ROUND(@Quantity * @EffectiveNewAmount, 2);
            SET @CalculatedTax = CASE 
                WHEN @EffectiveTaxRate > 0 THEN ROUND(@LineSubtotal * @EffectiveTaxRate, 2) 
                ELSE 0.0000 
            END;
            SET @CalculatedNet = @LineSubtotal + @CalculatedTax;
        END

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
            SYSDATETIME(), 
            @UserName, 
            @ActionType, 
            ISNULL(@DbOldWorkflowStatus, @OldWorkflowStatus), 
            @NewWorkflowStatus, 
            ISNULL(@DbOldAmount, ISNULL(@OldAmount, 0.0000)), 
            @EffectiveNewAmount, 
            @ReasonCode, 
            @InternalNotes
        );

        UPDATE PatientTransactions
        SET 
            CurrentWorkflowStatus = @NewWorkflowStatus,
            PerItemChargeAmount = @EffectiveNewAmount,
            TaxAmount = @CalculatedTax,
            NetAmount = @CalculatedNet
        WHERE TransactionGuid = @TransactionGuid;

        IF @TranCount = 0
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @TranCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @TranCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_InsertFeeManagementAudit;

        THROW;
    END CATCH
END;
GO