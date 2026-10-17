ALTER TABLE "runs"
  ADD COLUMN "spec_digest" text,
  ADD COLUMN "spec" jsonb;
--> statement-breakpoint
ALTER TABLE "run_attempts"
  ADD COLUMN "setup_manifest_digest" text;
--> statement-breakpoint
CREATE TABLE "run_secret_leases" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "attempt_id" uuid NOT NULL REFERENCES "run_attempts"("id") ON DELETE CASCADE,
  "owner_team_id" text NOT NULL,
  "secret_ref" text NOT NULL,
  "lease_hash" text NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "revoked_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "run_secret_leases_ref_nonempty" CHECK (length(trim("secret_ref")) > 0)
);--> statement-breakpoint
CREATE UNIQUE INDEX "run_secret_leases_attempt_ref_unique" ON "run_secret_leases" ("attempt_id", "secret_ref");--> statement-breakpoint
CREATE INDEX "run_secret_leases_scope_idx" ON "run_secret_leases" ("owner_team_id", "expires_at");
