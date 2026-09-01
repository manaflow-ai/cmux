-- Validate the provider CHECKs added NOT VALID by the previous migration
-- (20260831120000_coderouter_claude_provider). Running in a separate,
-- separately committed migration keeps each scan under SHARE UPDATE
-- EXCLUSIVE only, which never blocks reads or writes.
ALTER TABLE "coderouter_accounts"
  VALIDATE CONSTRAINT "coderouter_accounts_provider_check";
ALTER TABLE "coderouter_credentials"
  VALIDATE CONSTRAINT "coderouter_credentials_provider_check";
ALTER TABLE "coderouter_session_accounts"
  VALIDATE CONSTRAINT "coderouter_session_accounts_provider_check";
