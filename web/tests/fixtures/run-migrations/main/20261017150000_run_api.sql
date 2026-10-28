DO $$ BEGIN
  CREATE TYPE "run_status" AS ENUM ('queued', 'running', 'succeeded', 'failed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
DO $$ BEGIN
  CREATE TYPE "run_attempt_status" AS ENUM ('queued', 'running', 'succeeded', 'failed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
DO $$ BEGIN
  CREATE TYPE "run_event_kind" AS ENUM ('run.created', 'attempt.queued', 'attempt.started', 'attempt.succeeded', 'attempt.failed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "runs" (
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
  "completed_at" timestamp with time zone,
  "error" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "runs_desired_attempts_check" CHECK ("desired_attempts" between 1 and 32),
  CONSTRAINT "runs_provider_check" CHECK ("provider" = 'cloud-vm')
);--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "runs_user_idempotency_key_unique" ON "runs" ("user_id", "idempotency_key") WHERE "idempotency_key" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "runs_user_created_idx" ON "runs" ("user_id", "created_at", "id");--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "run_attempts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "ordinal" integer NOT NULL,
  "variant" jsonb NOT NULL,
  "status" "run_attempt_status" DEFAULT 'queued' NOT NULL,
  "provider_vm_id" text,
  "result" jsonb,
  "error" text,
  "started_at" timestamp with time zone,
  "finished_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "run_attempts_ordinal_check" CHECK ("ordinal" >= 0)
);--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_attempts_run_ordinal_unique" ON "run_attempts" ("run_id", "ordinal");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_attempts_run_status_idx" ON "run_attempts" ("run_id", "status");--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "run_events" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "run_id" uuid NOT NULL REFERENCES "runs"("id") ON DELETE CASCADE,
  "attempt_id" uuid REFERENCES "run_attempts"("id") ON DELETE CASCADE,
  "sequence" integer NOT NULL,
  "kind" "run_event_kind" NOT NULL,
  "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_events_run_sequence_unique" ON "run_events" ("run_id", "sequence");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_events_run_cursor_idx" ON "run_events" ("run_id", "sequence", "id");
