-- Validate the provider CHECKs added NOT VALID by the previous migration
-- (20260901090000_coderouter_apikey_providers). A separate, separately
-- committed migration keeps each scan under SHARE UPDATE EXCLUSIVE only.
ALTER TABLE "coderouter_accounts"
  VALIDATE CONSTRAINT "coderouter_accounts_provider_check";
ALTER TABLE "coderouter_credentials"
  VALIDATE CONSTRAINT "coderouter_credentials_provider_check";
ALTER TABLE "coderouter_session_accounts"
  VALIDATE CONSTRAINT "coderouter_session_accounts_provider_check";
