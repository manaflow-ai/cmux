ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'attempt.cancelled';--> statement-breakpoint
ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'run.cancelled';--> statement-breakpoint
ALTER TABLE "run_attempts" ADD COLUMN IF NOT EXISTS "lease_id" uuid;--> statement-breakpoint
ALTER TABLE "run_attempts" ADD COLUMN IF NOT EXISTS "lease_until" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "run_attempts" ADD COLUMN IF NOT EXISTS "worker_id" text;--> statement-breakpoint
ALTER TABLE "run_attempts" ADD COLUMN IF NOT EXISTS "cancel_requested_at" timestamp with time zone;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "run_attempts_lease_idx" ON "run_attempts" ("status", "lease_until", "created_at");
--> statement-breakpoint
ALTER TABLE "runs" ADD COLUMN IF NOT EXISTS "max_concurrent" integer NOT NULL DEFAULT 1;--> statement-breakpoint
DO $$ BEGIN
  ALTER TABLE "runs" ADD CONSTRAINT "runs_max_concurrent_check" CHECK ("max_concurrent" between 1 and 32);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
