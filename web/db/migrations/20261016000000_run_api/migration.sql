DO $$ BEGIN
  CREATE TYPE "run_status" AS ENUM ('queued', 'running', 'cancelling', 'succeeded', 'failed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
DO $$ BEGIN
  CREATE TYPE "run_attempt_status" AS ENUM ('queued', 'leased', 'running', 'succeeded', 'failed', 'cancelled', 'expired');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
DO $$ BEGIN
  CREATE TYPE "run_event_kind" AS ENUM ('run.created', 'attempt.queued', 'attempt.started', 'attempt.heartbeat', 'attempt.output', 'attempt.artifact', 'attempt.succeeded', 'attempt.failed', 'run.cancel_requested', 'run.completed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
-- Replay-safe: the enums above and the tables below are created only where they do not exist yet.
-- A database with main's Run model (main's 20261017150000_run_api and the migrations after it)
-- already has runs, run_attempts, run_events and run_artifacts in main's shape, so none of the
-- statements below run there, the indexes on next-only columns included. On a fresh database they
-- run unchanged and create exactly what this migration always created.
DO $$ BEGIN
IF to_regclass('public.runs') IS NULL THEN
CREATE TABLE "runs" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "billing_team_id" text,
  "idempotency_key" text,
  "request_digest" text NOT NULL,
  "source" jsonb NOT NULL,
  "recipe" text NOT NULL,
  "provider" text DEFAULT 'cloud-vm' NOT NULL,
  "desired_attempts" integer DEFAULT 1 NOT NULL,
  "status" "run_status" DEFAULT 'queued' NOT NULL,
  "cancel_requested_at" timestamp with time zone,
  "completed_at" timestamp with time zone,
  "error" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "runs_desired_attempts_check" CHECK ("desired_attempts" between 1 and 32),
  CONSTRAINT "runs_provider_check" CHECK ("provider" in ('cloud-vm'))
);
CREATE UNIQUE INDEX "runs_user_idempotency_key_unique" ON "runs" ("user_id", "idempotency_key") WHERE "idempotency_key" is not null;
CREATE INDEX "runs_user_created_idx" ON "runs" ("user_id", "created_at", "id");
CREATE INDEX "runs_status_updated_idx" ON "runs" ("status", "updated_at");
CREATE TABLE "run_attempts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "ordinal" integer NOT NULL,
  "status" "run_attempt_status" DEFAULT 'queued' NOT NULL,
  "provider_vm_id" text,
  "provider_workspace_id" text,
  "provider_terminal_id" text,
  "terminal_retain_until" timestamp with time zone,
  "attach_ticket_hash" text,
  "attach_ticket_expires_at" timestamp with time zone,
  "attach_ticket_consumed_at" timestamp with time zone,
  "cleanup_lease_token" text,
  "cleanup_lease_expires_at" timestamp with time zone,
  "lease_token" text,
  "lease_generation" integer DEFAULT 0 NOT NULL,
  "lease_expires_at" timestamp with time zone,
  "source_digest" text,
  "result" jsonb,
  "exit_code" integer,
  "error" text,
  "started_at" timestamp with time zone,
  "finished_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "run_attempts_lease_generation_check" CHECK ("lease_generation" >= 0)
);
CREATE UNIQUE INDEX "run_attempts_run_ordinal_unique" ON "run_attempts" ("run_id", "ordinal");
CREATE INDEX "run_attempts_lease_idx" ON "run_attempts" ("status", "lease_expires_at");
CREATE INDEX "run_attempts_terminal_retention_idx" ON "run_attempts" ("status", "terminal_retain_until", "cleanup_lease_expires_at");
CREATE INDEX "run_attempts_run_status_idx" ON "run_attempts" ("run_id", "status");
CREATE TABLE "run_events" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "attempt_id" uuid REFERENCES "run_attempts"("id") ON DELETE CASCADE,
  "sequence" integer NOT NULL,
  "attempt_sequence" integer,
  "external_id" text,
  "kind" "run_event_kind" NOT NULL,
  "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE UNIQUE INDEX "run_events_run_sequence_unique" ON "run_events" ("run_id", "sequence");
CREATE UNIQUE INDEX "run_events_attempt_external_unique" ON "run_events" ("attempt_id", "external_id") WHERE "attempt_id" is not null and "external_id" is not null;
CREATE UNIQUE INDEX "run_events_attempt_sequence_unique" ON "run_events" ("attempt_id", "attempt_sequence") WHERE "attempt_id" is not null and "attempt_sequence" is not null;
CREATE INDEX "run_events_run_cursor_idx" ON "run_events" ("run_id", "sequence", "id");
CREATE TABLE "run_artifacts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "attempt_id" uuid NOT NULL REFERENCES "run_attempts"("id") ON DELETE CASCADE,
  "name" text NOT NULL,
  "media_type" text DEFAULT 'application/octet-stream' NOT NULL,
  "size_bytes" integer NOT NULL,
  "digest" text NOT NULL,
  "uri" text NOT NULL,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "run_artifacts_size_check" CHECK ("size_bytes" >= 0 and "size_bytes" <= 536870912),
  CONSTRAINT "run_artifacts_digest_check" CHECK ("digest" ~ '^sha256:[0-9a-fA-F]{64}$')
);
CREATE UNIQUE INDEX "run_artifacts_attempt_name_unique" ON "run_artifacts" ("attempt_id", "name");
CREATE INDEX "run_artifacts_run_idx" ON "run_artifacts" ("run_id", "created_at", "id");
END IF;
END $$;
