ALTER TABLE "run_events"
  ADD COLUMN IF NOT EXISTS "writer_lease_generation" integer,
  ADD COLUMN IF NOT EXISTS "writer_lease_token_hash" text;--> statement-breakpoint
ALTER TABLE "run_artifacts"
  ADD COLUMN IF NOT EXISTS "writer_lease_generation" integer,
  ADD COLUMN IF NOT EXISTS "writer_lease_token_hash" text;
