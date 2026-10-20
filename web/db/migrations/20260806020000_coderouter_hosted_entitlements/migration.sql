-- Expand first. The application rejects unscoped rows after deployment; a
-- follow-up migration removes them and makes this column NOT NULL.
ALTER TABLE "coderouter_route_tokens"
  ADD COLUMN IF NOT EXISTS "stack_user_id" text;

CREATE INDEX IF NOT EXISTS "coderouter_route_tokens_user_expiry_idx"
  ON "coderouter_route_tokens" ("stack_user_id", "expires_at");
