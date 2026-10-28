-- =============================================================================
-- 20_encrypted_config.sql — PATTERN for seeding encrypted config in-container.
--
-- Certs/keys are regenerated fresh by the publish, so prod/dev ciphertext will NOT
-- decrypt here. Seed PLAINTEXT and re-encrypt under this container's key with the
-- same OPEN KEY / EncryptByKey pattern the app uses
-- (see route.ChannelRouteCredentialConfig_AddOrUpdate).
--
-- route.ChannelRouteCredentialConfig FKs to route.Channel (ChannelId, UNIQUEIDENTIFIER)
-- and route.VendorConn (ConnUid, SMALLINT) — both have their own parent chains that
-- are scenario-specific. This script therefore runs only when such parents already
-- exist (e.g. seeded by a scenario), and otherwise skips cleanly. Adapt the SELECTs
-- to your scenario's real ChannelId/ConnUid.
-- =============================================================================
-- DB context comes from the sqlcmd connection (-d), so the script is DB-name-agnostic.
-- QUOTED_IDENTIFIER/ANSI_NULLS ON required for INSERTs against indexed tables under sqlcmd.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

DECLARE @ChannelId UNIQUEIDENTIFIER = (SELECT MIN(ChannelId) FROM route.Channel);
DECLARE @ConnUid   SMALLINT         = (SELECT MIN(ConnUid)   FROM route.VendorConn);

IF @ChannelId IS NULL OR @ConnUid IS NULL
BEGIN
    PRINT 'Seed 20_encrypted_config.sql skipped: no route.Channel / route.VendorConn parent rows yet.';
    RETURN;
END

IF NOT EXISTS (SELECT 1 FROM route.ChannelRouteCredentialConfig
               WHERE ChannelId = @ChannelId AND ConnUid = @ConnUid)
BEGIN
    OPEN SYMMETRIC KEY ChannelRouteCredentialConfig_Key
        DECRYPTION BY CERTIFICATE ChannelRouteCredentialConfig;

    INSERT route.ChannelRouteCredentialConfig (ChannelId, AgentId, ClientId, ClientSecret, ConnUid)
    VALUES (@ChannelId, N'msginttest-agent', 'msginttest-client',
            EncryptByKey(Key_GUID('ChannelRouteCredentialConfig_Key'), 'test-secret'),  -- varchar: proc decrypts via CONVERT(varchar,..)
            @ConnUid);

    CLOSE SYMMETRIC KEY ChannelRouteCredentialConfig_Key;
    PRINT 'Seed 20_encrypted_config.sql: inserted 1 encrypted credential row.';
END
GO
