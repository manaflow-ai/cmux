-- Subrouter credential vault and device-code login state.
--
-- Vault entries are team-scoped: Stack Auth team membership is the authorization
-- boundary, so uploading an account to a team is the same act as sharing it.
-- The credential payload is stored as an AES-256-GCM envelope (ciphertext plus
-- nonce, key held outside the database in SR_VAULT_KEY) so a database dump alone
-- does not yield usable OAuth refresh chains.
CREATE TABLE IF NOT EXISTS "sr_vault_entries" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "team_id" text NOT NULL,
  "provider" text NOT NULL,
  "account_label" text NOT NULL,
  "ciphertext" text NOT NULL,
  "nonce" text NOT NULL,
  "key_version" integer DEFAULT 1 NOT NULL,
  "created_by_user_id" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
-- One row per team/provider/account: re-uploading refreshes in place rather than
-- accumulating duplicate credentials for the same account.
CREATE UNIQUE INDEX IF NOT EXISTS "sr_vault_entries_team_provider_account_unique"
  ON "sr_vault_entries" ("team_id", "provider", "account_label");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "sr_vault_entries_team_idx" ON "sr_vault_entries" ("team_id");
--> statement-breakpoint
-- Pending device-code logins. Only a digest of the CLI-held device code is
-- stored, so a dump cannot be replayed to complete a pending login.
CREATE TABLE IF NOT EXISTS "sr_device_codes" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_code" text NOT NULL,
  "device_code_hash" text NOT NULL,
  "user_id" text,
  "team_id" text,
  "approved_at" timestamp with time zone,
  "expires_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "sr_device_codes_user_code_unique" ON "sr_device_codes" ("user_code");
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "sr_device_codes_hash_unique" ON "sr_device_codes" ("device_code_hash");
--> statement-breakpoint
-- Supports the opportunistic sweep of expired rows on each start call.
CREATE INDEX IF NOT EXISTS "sr_device_codes_expires_idx" ON "sr_device_codes" ("expires_at");
