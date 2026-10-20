CREATE TABLE "coderouter_credentials" (
  "account_id" uuid PRIMARY KEY NOT NULL
    REFERENCES "coderouter_accounts" ("id") ON DELETE CASCADE,
  "team_id" text NOT NULL,
  "provider" text NOT NULL,
  "credential_revision" bigint NOT NULL,
  "algorithm" text DEFAULT 'aes-256-gcm' NOT NULL,
  "ciphertext" text NOT NULL,
  "nonce" text NOT NULL,
  "auth_tag" text NOT NULL,
  "encrypted_data_key" text NOT NULL,
  "kms_key_id" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "coderouter_credentials_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go')),
  CONSTRAINT "coderouter_credentials_revision_positive"
    CHECK ("credential_revision" > 0),
  CONSTRAINT "coderouter_credentials_algorithm_check"
    CHECK ("algorithm" = 'aes-256-gcm')
);

CREATE INDEX "coderouter_credentials_team_idx"
  ON "coderouter_credentials" ("team_id");
