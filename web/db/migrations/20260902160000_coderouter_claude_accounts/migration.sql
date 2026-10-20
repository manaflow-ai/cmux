-- Many Claude upstream accounts per team (any mix of Anthropic API keys,
-- Claude Code OAuth tokens, and Bedrock credentials) replace the one-row
-- coderouter_claude_upstreams table. Secret material stays KMS
-- envelope-encrypted; the single-upstream rows are carried over with
-- aad_version 1 (ciphertext bound to team+kind) and an empty identifier that
-- the service backfills on first read.
CREATE TABLE "coderouter_claude_accounts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "team_id" text NOT NULL,
  "kind" text NOT NULL,
  "label" text DEFAULT '' NOT NULL,
  "identifier" text DEFAULT '' NOT NULL,
  "state" text DEFAULT 'active' NOT NULL,
  "cooldown_until" timestamp with time zone,
  "last_used_at" timestamp with time zone,
  "last_failure_code" text,
  "algorithm" text DEFAULT 'aes-256-gcm' NOT NULL,
  "ciphertext" text NOT NULL,
  "nonce" text NOT NULL,
  "auth_tag" text NOT NULL,
  "encrypted_data_key" text NOT NULL,
  "kms_key_id" text NOT NULL,
  "aad_version" integer DEFAULT 2 NOT NULL,
  "config" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_by" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "coderouter_claude_accounts_kind_check"
    CHECK ("kind" IN ('anthropic_api_key', 'anthropic_oauth', 'bedrock')),
  CONSTRAINT "coderouter_claude_accounts_state_check"
    CHECK ("state" IN ('active', 'disabled')),
  CONSTRAINT "coderouter_claude_accounts_algorithm_check"
    CHECK ("algorithm" = 'aes-256-gcm'),
  CONSTRAINT "coderouter_claude_accounts_aad_version_check"
    CHECK ("aad_version" IN (1, 2))
);
--> statement-breakpoint
CREATE INDEX "coderouter_claude_accounts_team_state_idx"
  ON "coderouter_claude_accounts" ("team_id", "state");
--> statement-breakpoint
CREATE INDEX "coderouter_claude_accounts_cooldown_idx"
  ON "coderouter_claude_accounts" ("cooldown_until");
--> statement-breakpoint
INSERT INTO "coderouter_claude_accounts" (
  "team_id", "kind", "algorithm", "ciphertext", "nonce", "auth_tag",
  "encrypted_data_key", "kms_key_id", "aad_version", "config", "created_by",
  "created_at", "updated_at"
)
SELECT
  "team_id", "kind", "algorithm", "ciphertext", "nonce", "auth_tag",
  "encrypted_data_key", "kms_key_id", 1, "config", "updated_by",
  "created_at", "updated_at"
FROM "coderouter_claude_upstreams";
--> statement-breakpoint
DROP TABLE "coderouter_claude_upstreams";
