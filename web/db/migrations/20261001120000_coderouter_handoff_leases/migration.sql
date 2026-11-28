-- Native CodeRouter handoffs persist only a SHA-256 digest of the opaque
-- lease. The plaintext lease is returned to the caller and is never a column.
CREATE TABLE "coderouter_handoff_leases" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "team_id" text NOT NULL,
  "stack_user_id" text NOT NULL,
  "lease_hash" text NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "consumed_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "coderouter_handoff_leases_hash_format_check"
    CHECK ("lease_hash" ~ '^[0-9a-f]{64}$'),
  CONSTRAINT "coderouter_handoff_leases_expiry_check"
    CHECK ("expires_at" > "created_at")
);

CREATE UNIQUE INDEX "coderouter_handoff_leases_hash_unique"
  ON "coderouter_handoff_leases" ("lease_hash");
CREATE INDEX "coderouter_handoff_leases_expiry_idx"
  ON "coderouter_handoff_leases" ("expires_at");
CREATE INDEX "coderouter_handoff_leases_team_expiry_idx"
  ON "coderouter_handoff_leases" ("team_id", "expires_at");
CREATE INDEX "coderouter_handoff_leases_user_expiry_idx"
  ON "coderouter_handoff_leases" ("stack_user_id", "expires_at");
