-- =============================================================================
-- 30_authapi_key.sql — proposed test-safe workaround for the symmetric-key blocker
-- (PROJ-000 / PROJ-000, "Local SQL Step 1" dependencies).
--
-- WebAppFactory.GetApiKey() -> smsapi.AuthApi_GetApiKeys ->
--   OPEN SYMMETRIC KEY AuthApi_Key DECRYPTION BY CERTIFICATE AuthApi;
--   SELECT DECRYPTBYKEY(ApiKey_encrypt) ... FROM ms.AuthApi_Active
--
-- The AuthApi certificate's private key is NOT in source, so prod/dev ciphertext
-- cannot be decrypted in a fresh container. Restoring prod data does NOT help.
--
-- Workaround demonstrated here: seed a KNOWN PLAINTEXT test key, re-encrypted under
-- THIS container's freshly-generated AuthApi_Key. GetApiKey() then returns the
-- seeded value, so auth-dependent tests can run fully locally — provided the test
-- harness accepts a seeded test key rather than a specific production key value.
-- That harness decision is the "test-safe workaround to be agreed" the ticket tracks.
--
-- Depends on 10_accounts.sql (FK ms.AuthApi.AccountUid -> cp.Account). Idempotent.
-- =============================================================================
-- DB context comes from the sqlcmd connection (-d), so the script is DB-name-agnostic.
-- QUOTED_IDENTIFIER/ANSI_NULLS ON required for INSERTs against indexed tables under sqlcmd.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

DECLARE @AccountUid UNIQUEIDENTIFIER = 'E2E00000-0000-0000-0000-000000000001';
-- VARCHAR (not NVARCHAR): AuthApi_GetApiKeys decrypts via CONVERT(varchar, DECRYPTBYKEY(..)),
-- so the plaintext must be encrypted as varchar or the round-trip yields garbage.
DECLARE @ApiKey     VARCHAR(100)     = 'msginttest-api-key';  -- known plaintext for assertions

IF EXISTS (SELECT 1 FROM cp.Account WHERE AccountUid = @AccountUid)
   AND NOT EXISTS (SELECT 1 FROM ms.AuthApi WHERE AccountUid = @AccountUid AND Name = N'MsgIntTest API Key')
BEGIN
    OPEN SYMMETRIC KEY AuthApi_Key DECRYPTION BY CERTIFICATE AuthApi;

    INSERT ms.AuthApi (ApiKey_encrypt, AccountId, AccountUid, SubAccountId, SubAccountUid, Name, Active)
    VALUES (EncryptByKey(Key_GUID('AuthApi_Key'), @ApiKey),
            'MsgIntTest', @AccountUid, 'MsgIntTest_1', 1, N'MsgIntTest API Key', 1);

    CLOSE SYMMETRIC KEY AuthApi_Key;
    PRINT '  Seed 30_authapi_key.sql: inserted re-encrypted test API key.';
END
GO

PRINT 'Seed 30_authapi_key.sql applied.';
GO
