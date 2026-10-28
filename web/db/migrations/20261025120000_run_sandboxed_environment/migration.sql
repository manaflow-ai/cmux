ALTER TABLE "runs"
  ADD COLUMN IF NOT EXISTS "environment" text DEFAULT 'persistent' NOT NULL,
  ADD COLUMN IF NOT EXISTS "image_id" text,
  ADD COLUMN IF NOT EXISTS "image_version" text,
  ADD COLUMN IF NOT EXISTS "receipt" jsonb;--> statement-breakpoint
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'runs_environment_check' AND conrelid = '"runs"'::regclass) THEN
    ALTER TABLE "runs" ADD CONSTRAINT "runs_environment_check" CHECK ("environment" in ('persistent', 'sandboxed')) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'runs_sandboxed_single_attempt_check' AND conrelid = '"runs"'::regclass) THEN
    ALTER TABLE "runs" ADD CONSTRAINT "runs_sandboxed_single_attempt_check" CHECK ("environment" <> 'sandboxed' OR ("desired_attempts" = 1 AND "image_id" IS NOT NULL AND "billing_team_id" IS NOT NULL)) NOT VALID;
  END IF;
END $$;
