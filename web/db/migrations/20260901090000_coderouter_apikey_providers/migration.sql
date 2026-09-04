-- Provider API keys join the coderouter vault: widen the provider CHECKs so
-- accounts, encrypted credentials, and sticky session bindings can carry
-- 'anthropic-apikey' and 'openai-apikey' alongside the OAuth kinds.
--
-- Same lock-safe shape as 20260831120000_coderouter_claude_provider: the
-- replacement constraints are added NOT VALID here and validated in the next,
-- separately committed migration (20260901090100).
ALTER TABLE "coderouter_accounts"
  DROP CONSTRAINT "coderouter_accounts_provider_check";
ALTER TABLE "coderouter_accounts"
  ADD CONSTRAINT "coderouter_accounts_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go', 'claude', 'anthropic-apikey', 'openai-apikey')) NOT VALID;

ALTER TABLE "coderouter_credentials"
  DROP CONSTRAINT "coderouter_credentials_provider_check";
ALTER TABLE "coderouter_credentials"
  ADD CONSTRAINT "coderouter_credentials_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go', 'claude', 'anthropic-apikey', 'openai-apikey')) NOT VALID;

ALTER TABLE "coderouter_session_accounts"
  DROP CONSTRAINT "coderouter_session_accounts_provider_check";
ALTER TABLE "coderouter_session_accounts"
  ADD CONSTRAINT "coderouter_session_accounts_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go', 'claude', 'anthropic-apikey', 'openai-apikey')) NOT VALID;
