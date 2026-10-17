ALTER TABLE "run_attempts"
  ADD COLUMN "provider_workspace_id" text,
  ADD COLUMN "provider_terminal_id" text,
  ADD COLUMN "terminal_retain_until" timestamp with time zone,
  ADD COLUMN "cleanup_lease_token" text,
  ADD COLUMN "cleanup_lease_expires_at" timestamp with time zone;

CREATE INDEX "run_attempts_terminal_retention_idx"
  ON "run_attempts" ("status", "terminal_retain_until", "cleanup_lease_expires_at");
