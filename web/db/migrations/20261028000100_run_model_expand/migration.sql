-- Expand only: adds next's Run columns, indexes and constraints to main's Run tables, so main's
-- current code and next's code both work on the result. Nothing is dropped and no existing row is
-- rewritten; new NOT NULL columns carry defaults, so existing rows get the default and main's
-- inserts (which omit them) still pass. Every statement is a no-op where its object exists, which
-- covers a fresh database (next's 20261016000000_run_api created next's shape), staging's hybrid
-- and next's own databases.

-- runs
ALTER TABLE "runs" ADD COLUMN IF NOT EXISTS "cancel_requested_at" timestamp with time zone;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "runs_status_updated_idx" ON "runs" ("status", "updated_at");--> statement-breakpoint

-- run_attempts
ALTER TABLE "run_attempts"
  ADD COLUMN IF NOT EXISTS "provider_workspace_id" text,
  ADD COLUMN IF NOT EXISTS "provider_terminal_id" text,
  ADD COLUMN IF NOT EXISTS "terminal_retain_until" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "attach_ticket_hash" text,
  ADD COLUMN IF NOT EXISTS "attach_ticket_expires_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "attach_ticket_consumed_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "cleanup_lease_token" text,
  ADD COLUMN IF NOT EXISTS "cleanup_lease_expires_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "lease_token" text,
  ADD COLUMN IF NOT EXISTS "lease_generation" integer DEFAULT 0 NOT NULL,
  ADD COLUMN IF NOT EXISTS "lease_expires_at" timestamp with time zone,
  ADD COLUMN IF NOT EXISTS "source_digest" text,
  ADD COLUMN IF NOT EXISTS "exit_code" integer,
  ADD COLUMN IF NOT EXISTS "runtime_id" uuid;--> statement-breakpoint
-- main's variant stays for main's code; the default lets next's inserts omit it.
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'run_attempts' AND column_name = 'variant'
  ) THEN
    ALTER TABLE "run_attempts" ALTER COLUMN "variant" SET DEFAULT '{}'::jsonb;
  END IF;
END $$;--> statement-breakpoint
-- main's run_attempts_lease_idx is (status, lease_until) and main's code still uses it, so next's
-- (status, lease_expires_at) index takes another name until the contract step renames it.
CREATE INDEX IF NOT EXISTS "run_attempts_lease_expires_idx" ON "run_attempts" ("status", "lease_expires_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_attempts_terminal_retention_idx" ON "run_attempts" ("status", "terminal_retain_until", "cleanup_lease_expires_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_attempts_runtime_idx" ON "run_attempts" ("runtime_id", "created_at", "id");--> statement-breakpoint
-- NOT VALID: new writes are checked at once; existing rows are checked by 20261028000200_run_model_validate.
-- main's runtime_id has no FK and may hold ids of runtimes that are gone. A database that already has an
-- FK on the column (next's inline REFERENCES) keeps it; the one added here takes the name Postgres gave
-- that inline FK, so every database ends with the same constraint.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'run_attempts_lease_generation_check' AND conrelid = '"run_attempts"'::regclass
  ) THEN
    ALTER TABLE "run_attempts" ADD CONSTRAINT "run_attempts_lease_generation_check" CHECK ("lease_generation" >= 0) NOT VALID;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = '"run_attempts"'::regclass AND contype = 'f'
      AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = '"run_attempts"'::regclass AND attname = 'runtime_id')]
  ) THEN
    ALTER TABLE "run_attempts" ADD CONSTRAINT "run_attempts_runtime_id_fkey"
      FOREIGN KEY ("runtime_id") REFERENCES "cloud_runtimes"("id") ON DELETE SET NULL NOT VALID;
  END IF;
END $$;--> statement-breakpoint

-- run_events
ALTER TABLE "run_events"
  ADD COLUMN IF NOT EXISTS "attempt_sequence" integer,
  ADD COLUMN IF NOT EXISTS "external_id" text;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_events_attempt_external_unique" ON "run_events" ("attempt_id", "external_id") WHERE "attempt_id" is not null and "external_id" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "run_events_attempt_sequence_unique" ON "run_events" ("attempt_id", "attempt_sequence") WHERE "attempt_id" is not null and "attempt_sequence" is not null;--> statement-breakpoint

-- run_artifacts. main's rows are inline JSON receipts, hence media_type 'application/json', the default
-- main's 20261018120000_run_artifacts_schema_compat already gives this column where it exists. uri gets
-- the same default schema_compat gives it, so main's inserts (which omit both) still pass. next's code
-- always writes both.
ALTER TABLE "run_artifacts"
  ADD COLUMN IF NOT EXISTS "media_type" text DEFAULT 'application/json' NOT NULL,
  ADD COLUMN IF NOT EXISTS "uri" text DEFAULT 'inline://cmux-run-artifact' NOT NULL,
  ADD COLUMN IF NOT EXISTS "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_artifacts_run_idx" ON "run_artifacts" ("run_id", "created_at", "id");--> statement-breakpoint
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'run_artifacts_size_check' AND conrelid = '"run_artifacts"'::regclass
  ) THEN
    ALTER TABLE "run_artifacts" ADD CONSTRAINT "run_artifacts_size_check" CHECK ("size_bytes" >= 0 and "size_bytes" <= 536870912) NOT VALID;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'run_artifacts_digest_check' AND conrelid = '"run_artifacts"'::regclass
  ) THEN
    ALTER TABLE "run_artifacts" ADD CONSTRAINT "run_artifacts_digest_check" CHECK ("digest" ~ '^sha256:[0-9a-fA-F]{64}$') NOT VALID;
  END IF;
END $$;
