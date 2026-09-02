-- Claude Max joins the coderouter vault: widen the provider CHECKs so
-- accounts, encrypted credentials, and sticky session bindings can carry
-- provider 'claude' alongside 'codex' and 'opencode-go'.
--
-- The replacement constraints are added NOT VALID so this migration's
-- transaction never scans a table while holding the ALTERs' exclusive locks.
-- Validation happens in the next migration
-- (20260831120100_coderouter_claude_provider_validate), which commits
-- separately and takes only SHARE UPDATE EXCLUSIVE per table.
ALTER TABLE "coderouter_accounts"
  DROP CONSTRAINT "coderouter_accounts_provider_check";
ALTER TABLE "coderouter_accounts"
  ADD CONSTRAINT "coderouter_accounts_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go', 'claude')) NOT VALID;

ALTER TABLE "coderouter_credentials"
  DROP CONSTRAINT "coderouter_credentials_provider_check";
ALTER TABLE "coderouter_credentials"
  ADD CONSTRAINT "coderouter_credentials_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go', 'claude')) NOT VALID;

ALTER TABLE "coderouter_session_accounts"
  DROP CONSTRAINT "coderouter_session_accounts_provider_check";
ALTER TABLE "coderouter_session_accounts"
  ADD CONSTRAINT "coderouter_session_accounts_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go', 'claude')) NOT VALID;
