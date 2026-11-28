CREATE TABLE "coderouter_accounts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "team_id" text NOT NULL,
  "provider" text NOT NULL,
  "provider_account_id" text NOT NULL,
  "label" text NOT NULL,
  "state" text DEFAULT 'active' NOT NULL,
  "vault_revision" bigint DEFAULT 1 NOT NULL,
  "credential_expires_at" timestamp with time zone,
  "refresh_lease_id" uuid,
  "refresh_lease_expires_at" timestamp with time zone,
  "last_used_at" timestamp with time zone,
  "last_failure_code" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "coderouter_accounts_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go')),
  CONSTRAINT "coderouter_accounts_state_check"
    CHECK ("state" IN ('active', 'refreshing', 'expired', 'broken')),
  CONSTRAINT "coderouter_accounts_vault_revision_positive"
    CHECK ("vault_revision" > 0)
);
CREATE UNIQUE INDEX "coderouter_accounts_team_provider_account_unique"
  ON "coderouter_accounts" ("team_id", "provider", "provider_account_id");
CREATE INDEX "coderouter_accounts_team_provider_state_idx"
  ON "coderouter_accounts" ("team_id", "provider", "state");
CREATE INDEX "coderouter_accounts_refresh_lease_expiry_idx"
  ON "coderouter_accounts" ("refresh_lease_expires_at");

CREATE TABLE "coderouter_route_tokens" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "team_id" text NOT NULL,
  "token_hash" text NOT NULL,
  "label" text DEFAULT 'cli' NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "last_used_at" timestamp with time zone,
  "revoked_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE UNIQUE INDEX "coderouter_route_tokens_hash_unique"
  ON "coderouter_route_tokens" ("token_hash");
CREATE INDEX "coderouter_route_tokens_team_expiry_idx"
  ON "coderouter_route_tokens" ("team_id", "expires_at");

CREATE TABLE "coderouter_vault_leases" (
  "team_id" text PRIMARY KEY NOT NULL,
  "lease_id" uuid NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE INDEX "coderouter_vault_leases_expiry_idx"
  ON "coderouter_vault_leases" ("expires_at");
