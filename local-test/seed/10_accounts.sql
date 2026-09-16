-- =============================================================================
-- 10_accounts.sql — the MsgIntTest target account + one SMS-enabled subaccount.
--
-- Depends on 00_lookups.sql (FK parents). Uses a FIXED AccountUid so tests and
-- other seed files can reference the account deterministically. Columns not set
-- fall to their table defaults, which already satisfy every CHECK/FK:
--   CustomerType -> 'L'  => CK_Account_ManagerId ok (ManagerId NULL allowed)
--                        => CK_Account_BillingMode ok
--   CompanyEntity -> 'WSG', RegionId/BusinessUnitId/TierId/
--   CustomerSegmentId/AccountGroupId -> 0  (all seeded in 00_lookups.sql)
-- Idempotent: safe to re-run.
-- =============================================================================
-- DB context comes from the sqlcmd connection (-d), so the script is DB-name-agnostic.
-- QUOTED_IDENTIFIER/ANSI_NULLS ON are required to INSERT into tables with filtered
-- indexes or computed columns (e.g. core.Account) — sqlcmd defaults QUOTED_IDENTIFIER OFF.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- Fixed identity for the test account (mnemonic 'E2E').
DECLARE @AccountUid UNIQUEIDENTIFIER = 'E2E00000-0000-0000-0000-000000000001';

IF NOT EXISTS (SELECT 1 FROM core.Account WHERE AccountId = 'MsgIntTest')
    INSERT core.Account (AccountUid, AccountId, AccountName, CustomerType, Product_SMS)
    VALUES (@AccountUid, 'MsgIntTest', 'MsgIntTest', 'L', 1);

-- One SMS-enabled subaccount under the account.
-- SubAccountUid is NOT an identity column, so supply it explicitly.
IF NOT EXISTS (SELECT 1 FROM svc.SubAccount WHERE SubAccountId = 'MsgIntTest_1')
    INSERT svc.SubAccount (SubAccountUid, SubAccountId, AccountUid, Active, Product_SMS, OmnishieldStatusId)
    VALUES (1, 'MsgIntTest_1', @AccountUid, 1, 1, 0);
GO

PRINT 'Seed 10_accounts.sql applied.';
GO
