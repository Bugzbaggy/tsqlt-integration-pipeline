-- =============================================================================
-- verify.sql — end-to-end smoke test for the ephemeral AppDb_MSG test DB (PROJ-000).
--
-- Runs AFTER publish + seed. Each check THROWs (severity 16) on failure, so under
-- `sqlcmd -b` the batch aborts with a non-zero exit and db-up fails loudly. Prints
-- a line per passing check so the run log doubles as validation evidence.
--
-- Proves each Step-1 blocker was actually resolved, not just that publish "ran":
--   1. Schema fully published        (object counts)
--   2. DMK + certs + key round-trip  (blockers #2/#3 — the subtle ones)
--   3. Filegroup files present        (blocker #5 — partitioned table is real)
--   4. MsgIntTest seed present        (the target account + subaccount)
-- =============================================================================
-- DB context comes from the sqlcmd connection (-d), so the script is DB-name-agnostic.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- 1. Schema published across ALL object types (floors allow drift). Views are the
--    strictest check: they validate their table/synonym targets at CREATE time, so a
--    healthy view count proves the cross-DB synonym wiring resolved.
DECLARE @tables   INT = (SELECT COUNT(*) FROM sys.tables    WHERE is_ms_shipped = 0);
DECLARE @views    INT = (SELECT COUNT(*) FROM sys.views     WHERE is_ms_shipped = 0);
DECLARE @synonyms INT = (SELECT COUNT(*) FROM sys.synonyms);
DECLARE @procs    INT = (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0);
DECLARE @funcs    INT = (SELECT COUNT(*) FROM sys.objects   WHERE type IN ('FN','IF','TF') AND is_ms_shipped = 0);
DECLARE @triggers INT = (SELECT COUNT(*) FROM sys.triggers  WHERE is_ms_shipped = 0 AND parent_class = 1);
IF @tables   < 300 THROW 50001, 'Schema publish incomplete: table count below floor.', 1;
IF @procs    < 900 THROW 50002, 'Schema publish incomplete: procedure count below floor.', 1;
IF @views    < 100 THROW 50011, 'Schema publish incomplete: view count below floor.', 1;
IF @synonyms <  80 THROW 50012, 'Schema publish incomplete: synonym count below floor.', 1;
IF @funcs    <  30 THROW 50013, 'Schema publish incomplete: function count below floor.', 1;
IF @triggers < 120 THROW 50014, 'Schema publish incomplete: trigger count below floor.', 1;
PRINT CONCAT('  [OK] schema published: ', @tables, ' tables, ', @views, ' views, ', @synonyms,
             ' synonyms, ', @procs, ' procs, ', @funcs, ' functions, ', @triggers, ' triggers.');

-- 2. Encryption chain works: DMK exists, all 7 app certs present, and a full
--    EncryptByKey/DecryptByKey round-trip returns the original plaintext.
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    THROW 50003, 'Database Master Key missing (bootstrap.sql did not run?).', 1;

DECLARE @certs INT = (SELECT COUNT(*) FROM sys.certificates WHERE name NOT LIKE '##%');
IF @certs < 7 THROW 50004, 'Expected 7 application certificates; fewer found.', 1;

DECLARE @plain NVARCHAR(100) = N'verify-secret';
OPEN SYMMETRIC KEY ChannelRouteCredentialConfig_Key
    DECRYPTION BY CERTIFICATE ChannelRouteCredentialConfig;
DECLARE @roundtrip NVARCHAR(100) = CONVERT(NVARCHAR(100),
    DecryptByKey(EncryptByKey(Key_GUID('ChannelRouteCredentialConfig_Key'), @plain)));
CLOSE SYMMETRIC KEY ChannelRouteCredentialConfig_Key;
IF @roundtrip IS NULL OR @roundtrip <> @plain
    THROW 50005, 'Encryption round-trip failed: DMK/cert/key chain is not usable.', 1;
PRINT CONCAT('  [OK] encryption chain: DMK + ', @certs, ' certs, round-trip verified.');

-- 3. Filegroup files present -> the only partitioned table (route.PriceListHistory)
--    exists on its partition scheme. Fails if bootstrap.sql skipped the FG files.
IF EXISTS (
    SELECT 1 FROM sys.filegroups fg
    LEFT JOIN sys.database_files df ON df.data_space_id = fg.data_space_id
    WHERE fg.name LIKE 'FG[_]0%' AND df.file_id IS NULL)
    THROW 50006, 'A FG_0x filegroup has no data file.', 1;
IF NOT EXISTS (
    SELECT 1
    FROM sys.tables t
    JOIN sys.indexes i ON i.object_id = t.object_id AND i.index_id <= 1
    JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
    WHERE t.name = 'PriceListHistory' AND ds.type = 'PS')
    THROW 50007, 'route.PriceListHistory is missing or not on a partition scheme (FG files?).', 1;
PRINT '  [OK] filegroups have files; route.PriceListHistory partitioned.';

-- 4. MsgIntTest seed present and correctly linked.
IF NOT EXISTS (SELECT 1 FROM core.Account WHERE AccountId = 'MsgIntTest')
    THROW 50008, 'Seed missing: core.Account MsgIntTest not found.', 1;
IF NOT EXISTS (
    SELECT 1 FROM svc.SubAccount sa
    JOIN core.Account a ON a.AccountUid = sa.AccountUid
    WHERE a.AccountId = 'MsgIntTest' AND sa.SubAccountId = 'MsgIntTest_1' AND sa.Product_SMS = 1)
    THROW 50009, 'Seed missing: SMS-enabled subaccount MsgIntTest_1 not linked to MsgIntTest.', 1;
PRINT '  [OK] seed present: MsgIntTest account + SMS subaccount.';

-- 5. Symmetric-key blocker workaround: WebAppFactory.GetApiKey() equivalent.
--    Execute the real proc and confirm it decrypts back to the seeded plaintext,
--    proving the fresh-cert re-encryption approach makes auth-dependent tests viable.
IF EXISTS (SELECT 1 FROM svc.AuthApi WHERE Name = N'MsgIntTest API Key')
BEGIN
    DECLARE @keys TABLE (ApiKey VARCHAR(3000), ApiKeyId INT, AccountId VARCHAR(50), SubAccountId VARCHAR(50));
    INSERT @keys EXEC smsapi.AuthApi_GetApiKeys;
    IF NOT EXISTS (SELECT 1 FROM @keys WHERE ApiKey = 'msginttest-api-key')
        THROW 50010, 'AuthApi workaround failed: GetApiKeys did not return the seeded plaintext key.', 1;
    PRINT '  [OK] symmetric-key workaround: AuthApi_GetApiKeys decrypts seeded key.';
END
ELSE
    PRINT '  [--] symmetric-key workaround: AuthApi test key not seeded (30_authapi_key.sql skipped).';

PRINT 'VERIFY OK — AppDb_MSG test database passed all smoke checks.';
GO
