-- =============================================================================
-- 00_lookups.sql — FK-parent lookup rows the MsgIntTest account/subaccount need.
--
-- core.Account has NOT-NULL foreign keys (each defaulting to 0 / 'WSG') to these
-- lookups, so the parent rows must exist before the account inserts. svc.SubAccount
-- additionally needs omnishield.OmnishieldStatus. All lookups here are IDENTITY(0,1)
-- (except DimCompany/Region), so id 0 is inserted with IDENTITY_INSERT.
-- Idempotent: safe to re-run.
--
-- Nullable Account FKs (ManagerId, CompanyId, PartnerId, Country, SupplierId) are
-- left NULL, so core.AccountOwner / crm.Company / svc.Partner / mno.Country /
-- svc.Vendor deliberately need no seed row.
-- =============================================================================
-- DB context comes from the sqlcmd connection (-d), so the script is DB-name-agnostic.
-- QUOTED_IDENTIFIER/ANSI_NULLS ON are required to INSERT into tables with filtered
-- indexes or computed columns (e.g. core.Account) — sqlcmd defaults QUOTED_IDENTIFIER OFF.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- Account.CompanyEntity defaults to 'WSG' -> that entity must exist.
IF NOT EXISTS (SELECT 1 FROM core.DimCompany WHERE CompanyEntity = 'WSG')
    INSERT core.DimCompany (CompanyEntity, Country, CompanyName)
    VALUES ('WSG', 'SG', 'AppDb Pte Ltd');
GO

-- Account.RegionId defaults to 0. Routing columns are placeholders for Step 1
-- (single DB); they only matter once cross-region sends are exercised.
IF NOT EXISTS (SELECT 1 FROM dbo.Region WHERE RegionId = 0)
    INSERT dbo.Region (RegionId, RegionName, Country, LinkedServerName, MSG_Data_DBName)
    VALUES (0, 'SG', 'SG', N'localhost', 'AppDb_MSG');
GO

IF NOT EXISTS (SELECT 1 FROM core.BusinessUnit WHERE BusinessUnitId = 0)
BEGIN
    SET IDENTITY_INSERT core.BusinessUnit ON;
    INSERT core.BusinessUnit (BusinessUnitId, BusinessUnit) VALUES (0, 'Default');
    SET IDENTITY_INSERT core.BusinessUnit OFF;
END
GO

IF NOT EXISTS (SELECT 1 FROM core.Tier WHERE TierId = 0)
BEGIN
    SET IDENTITY_INSERT core.Tier ON;
    INSERT core.Tier (TierId, Tier) VALUES (0, 'Default');
    SET IDENTITY_INSERT core.Tier OFF;
END
GO

IF NOT EXISTS (SELECT 1 FROM core.CustomerSegment WHERE CustomerSegmentId = 0)
BEGIN
    SET IDENTITY_INSERT core.CustomerSegment ON;
    INSERT core.CustomerSegment (CustomerSegmentId, CustomerSegment) VALUES (0, 'Default');
    SET IDENTITY_INSERT core.CustomerSegment OFF;
END
GO

IF NOT EXISTS (SELECT 1 FROM core.AccountGroup WHERE AccountGroupId = 0)
BEGIN
    SET IDENTITY_INSERT core.AccountGroup ON;
    INSERT core.AccountGroup (AccountGroupId, AccountGroup) VALUES (0, 'Default');
    SET IDENTITY_INSERT core.AccountGroup OFF;
END
GO

-- SubAccount.OmnishieldStatusId defaults to 0.
IF NOT EXISTS (SELECT 1 FROM omnishield.OmnishieldStatus WHERE OmnishieldStatusId = 0)
BEGIN
    SET IDENTITY_INSERT omnishield.OmnishieldStatus ON;
    INSERT omnishield.OmnishieldStatus (OmnishieldStatusId, OmnishieldStatus) VALUES (0, 'None');
    SET IDENTITY_INSERT omnishield.OmnishieldStatus OFF;
END
GO

PRINT 'Seed 00_lookups.sql applied.';
GO
