-- ==========================================================================================
-- LEDGER SCHEMA: Surgical Professional Payout Matrix
-- ==========================================================================================

CREATE TABLE ClinicalGeniusSupplyChain.dbo.SurgicalProfessionalPayouts (
    PayoutGuid NVARCHAR(50) PRIMARY KEY DEFAULT NEWID(),
    FacilityId NVARCHAR(50) NOT NULL,
    PatientVisit NVARCHAR(50) NOT NULL,
    SurgeryGuid NVARCHAR(50) NOT NULL,
    TransactionGuid NVARCHAR(50) NOT NULL, -- Links back to your PatientTransactions tracking row
    ProviderId NVARCHAR(50) NOT NULL,          -- Identifies the specific surgeon, anesthesiologist, or assistant
    RoleType VARCHAR(30) NOT NULL,             -- 'Cirujano', 'Anestesiologo', 'Ayudante', etc.
    CUPSCode VARCHAR(10) NOT NULL,
    CalculatedUnits DECIMAL(18,2) NOT NULL,    -- Stores the raw UVR or UVB points after degradation
    BaseUnitValue DECIMAL(18,2) NOT NULL,      -- The baseline monetary unit value for that fiscal year
    AppliedFactor DECIMAL(10,4) NOT NULL,      -- The contract adjustment percentage modifier factor
    GrossPayoutCOP DECIMAL(18,2) NOT NULL,     -- The finalized amount owed to the professional
    PaymentStatus VARCHAR(20) NOT NULL DEFAULT 'Pending', -- 'Pending', 'Processed', 'Paid'
    DateTimeEntered DATETIME DEFAULT GETDATE(),
    LastUpdatedBy NVARCHAR(100) DEFAULT 'PayoutDistributionEngine'
);

CREATE NONCLUSTERED INDEX IX_SurgicalProfessionalPayouts_Facility_Provider 
ON ClinicalGeniusSupplyChain.dbo.SurgicalProfessionalPayouts (FacilityId, ProviderId)
INCLUDE (GrossPayoutCOP, PaymentStatus);
GO
