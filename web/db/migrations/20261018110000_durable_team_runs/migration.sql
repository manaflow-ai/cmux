ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'attempt.cancelled';--> statement-breakpoint
ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'run.cancelled';--> statement-breakpoint
ALTER TABLE "runs" ADD COLUMN IF NOT EXISTS "owner_team_id" text;
ALTER TABLE "runs" ADD COLUMN IF NOT EXISTS "spec" jsonb;
DROP INDEX IF EXISTS "runs_user_idempotency_key_unique";
CREATE UNIQUE INDEX IF NOT EXISTS "runs_user_idempotency_key_unique" ON "runs" ("user_id", "idempotency_key") WHERE "owner_team_id" IS NULL AND "idempotency_key" IS NOT NULL;
-- Legacy rows stay user-scoped; they are never silently transferred to a billing team.
CREATE UNIQUE INDEX IF NOT EXISTS "runs_owner_idempotency_unique" ON "runs" ("owner_team_id", "idempotency_key") WHERE "owner_team_id" IS NOT NULL AND "idempotency_key" IS NOT NULL;
ALTER TABLE "run_attempts"
  ADD COLUMN IF NOT EXISTS "lease_id" uuid,
  ADD COLUMN IF NOT EXISTS "lease_until" timestamptz,
  ADD COLUMN IF NOT EXISTS "worker_id" text,
  ADD COLUMN IF NOT EXISTS "cancel_requested_at" timestamptz,
  ADD COLUMN IF NOT EXISTS "checkpoint" jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS "cleanup_state" text NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS "retained_until" timestamptz,
  ADD COLUMN IF NOT EXISTS "promoted_at" timestamptz,
  ADD COLUMN IF NOT EXISTS "runtime_id" uuid;
CREATE INDEX IF NOT EXISTS "run_attempts_lease_idx" ON "run_attempts" ("status", "lease_until");
CREATE TABLE IF NOT EXISTS "run_artifacts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "attempt_id" uuid NOT NULL REFERENCES "run_attempts"("id") ON DELETE CASCADE,
  "name" text NOT NULL,
  "digest" text NOT NULL,
  "payload" jsonb NOT NULL,
  "size_bytes" integer NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS "run_artifacts_attempt_name_unique" ON "run_artifacts" ("attempt_id", "name");
CREATE TABLE IF NOT EXISTS "run_attach_tickets" (
  "digest" text PRIMARY KEY,
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "attempt_id" uuid NOT NULL REFERENCES "run_attempts"("id") ON DELETE CASCADE,
  "owner_team_id" text NOT NULL,
  "user_id" text NOT NULL,
  "provider_vm_id" text NOT NULL,
  "expires_at" timestamptz NOT NULL,
  "redeemed_at" timestamptz
);
