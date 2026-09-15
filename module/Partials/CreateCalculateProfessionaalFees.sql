-- ==========================================================================================
-- DISTRIBUTION PROCEDURE: Automated Surgical Professional Payout Computation
-- ==========================================================================================

CREATE PROCEDURE ClinicalGeniusSupplyChain.usp_CalculateSurgicalPayouts
    @PatientVisit NVARCHAR(50),
    @FacilityId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Open atomic transaction to prevent fractured accounting runs
    BEGIN TRAN;
    BEGIN TRY

        -- 1. Soft-Clear any previous pending computations for this visit to avoid double-allocation errors
        DELETE FROM ClinicalGeniusSupplyChain.dbo.SurgicalProfessionalPayouts
        WHERE PatientVisit = @PatientVisit
          AND FacilityId = @FacilityId
          AND PaymentStatus = 'Pending';

        -- 2. Extract, compute, and seed the professional payout ledger table
        INSERT INTO ClinicalGeniusSupplyChain.dbo.SurgicalProfessionalPayouts (
            FacilityId, PatientVisit, SurgeryGuid, TransactionGuid, ProviderId, 
            RoleType, CUPSCode, CalculatedUnits, BaseUnitValue, AppliedFactor, GrossPayoutCOP
        )
        SELECT 
            pt.Facility,
            pt.PatientVisit,
            pt.SurgeryGuid,
            pt.TransactionGuid,
            -- DYNAMIC PROVIDER RESOLUTION PATH:
            -- Maps the correct clinical identifier tracking token based on the component role type
            CASE 
                WHEN pt.SurgicalComponent LIKE 'Cirujano%' THEN s.SurgeonId
                WHEN pt.SurgicalComponent LIKE 'Anestesiologo%' THEN s.Anesthesiologist
                WHEN pt.SurgicalComponent LIKE 'Ayudante%' THEN s.SurgeonId2
                WHEN pt.SurgicalComponent LIKE 'Segundo Ayudante%' THEN s.SurgeonId3
                ELSE 'UNKNOWN_PROVIDER'
            END AS ProviderId,
            pt.SurgicalComponent AS RoleType,
            pt.CupsCode AS CUPSCode,
            -- Re-hydrates the true, un-zeroed point weights (BaseUnits * MultiSurgeryMultiplier * DegradationMultiplier)
            CAST(pt.ItemAlternateCode * pt.USDBasePrice AS DECIMAL(18,2)) AS CalculatedUnits,
            pt.BaseUnitValue,
            pt.LocalAmount AS AppliedFactor,
            -- FINAL PROFESSIONAL COP OUT-PAYMENT MATHEMATICAL MATRIX:
            -- (Raw Point Catalog Units * Degradation Multiplier * Shift Premium Factor * Base Monetary Value * Applied Contract Modifier Margin)
            CAST(
                (pt.ItemAlternateCode * pt.USDBasePrice * pt.USDPerItemChargeAmount * pt.BaseUnitValue * pt.LocalAmount) 
                AS DECIMAL(18,2)
            ) AS GrossPayoutCOP
        FROM ClinicalGeniusSupplyChain.dbo.PatientTransactions pt WITH(NOLOCK)
        INNER JOIN ClinicalGeniusEhr.dbo.ScheduledSurgeries s WITH(NOLOCK) ON s.SurgeryGuid = pt.SurgeryGuid
        WHERE pt.PatientVisit = @PatientVisit
          AND pt.Facility = @FacilityId
          AND pt.Status = 'Active'
          -- Scopes exclusively to professional honorary lines (Omits RoomRights, Supplies, and Master Bundle anchors)
          AND pt.TransactionType = 'Honorary'
          -- Safeguard check: Excludes lines where doctors weren't assigned or mapped to the operational case
          AND CASE 
                WHEN pt.SurgicalComponent LIKE 'Cirujano%' THEN s.SurgeonId
                WHEN pt.SurgicalComponent LIKE 'Anestesiologo%' THEN s.Anesthesiologist
                WHEN pt.SurgicalComponent LIKE 'Ayudante%' THEN s.SurgeonId2
                WHEN pt.SurgicalComponent LIKE 'Segundo Ayudante%' THEN s.SurgeonId3
                ELSE NULL
              END IS NOT NULL;

        COMMIT TRAN;

        -- Return analytical clearance audit validation metrics to the application coordinator
        SELECT 
            ProviderId,
            RoleType,
            COUNT(TransactionGuid) AS TotalProceduresCalculated,
            SUM(GrossPayoutCOP) AS TotalOwedCOP
        FROM ClinicalGeniusSupplyChain.dbo.SurgicalProfessionalPayouts
        WHERE PatientVisit = @PatientVisit AND FacilityId = @FacilityId
        GROUP BY ProviderId, RoleType;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE(),
                @ErrorSeverity INT = ERROR_SEVERITY(),
                @ErrorState INT = ERROR_STATE();
                
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH
END;
GO
