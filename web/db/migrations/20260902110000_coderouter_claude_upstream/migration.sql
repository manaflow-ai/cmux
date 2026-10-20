-- One Claude upstream per team for the coderouter /v1/messages leg.
-- Secret material is KMS envelope-encrypted like coderouter_credentials;
-- config carries only non-secret settings (Bedrock region, model overrides).
CREATE TABLE "coderouter_claude_upstreams" (
  "team_id" text PRIMARY KEY,
  "kind" text NOT NULL,
  "algorithm" text DEFAULT 'aes-256-gcm' NOT NULL,
  "ciphertext" text NOT NULL,
  "nonce" text NOT NULL,
  "auth_tag" text NOT NULL,
  "encrypted_data_key" text NOT NULL,
  "kms_key_id" text NOT NULL,
  "config" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "updated_by" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "coderouter_claude_upstreams_kind_check"
    CHECK ("kind" IN ('anthropic_api_key', 'anthropic_oauth', 'bedrock')),
  CONSTRAINT "coderouter_claude_upstreams_algorithm_check"
    CHECK ("algorithm" = 'aes-256-gcm')
);
