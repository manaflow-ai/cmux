-- coderouter routes the OpenAI Responses surface through pasted OpenAI and
-- OpenRouter API keys as well as Codex sign-ins. The provider check on every
-- coderouter table widens to admit the two key-based providers.
ALTER TABLE "coderouter_accounts"
  DROP CONSTRAINT IF EXISTS "coderouter_accounts_provider_check";
ALTER TABLE "coderouter_accounts"
  ADD CONSTRAINT "coderouter_accounts_provider_check"
  CHECK ("provider" IN ('codex', 'opencode-go', 'openai-apikey', 'openrouter-apikey'));

ALTER TABLE "coderouter_credentials"
  DROP CONSTRAINT IF EXISTS "coderouter_credentials_provider_check";
ALTER TABLE "coderouter_credentials"
  ADD CONSTRAINT "coderouter_credentials_provider_check"
  CHECK ("provider" IN ('codex', 'opencode-go', 'openai-apikey', 'openrouter-apikey'));

ALTER TABLE "coderouter_session_accounts"
  DROP CONSTRAINT IF EXISTS "coderouter_session_accounts_provider_check";
ALTER TABLE "coderouter_session_accounts"
  ADD CONSTRAINT "coderouter_session_accounts_provider_check"
  CHECK ("provider" IN ('codex', 'opencode-go', 'openai-apikey', 'openrouter-apikey'));
