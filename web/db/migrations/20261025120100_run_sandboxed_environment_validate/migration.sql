ALTER TABLE "runs" VALIDATE CONSTRAINT "runs_environment_check";--> statement-breakpoint
ALTER TABLE "runs" VALIDATE CONSTRAINT "runs_sandboxed_single_attempt_check";--> statement-breakpoint
CREATE INDEX CONCURRENTLY IF NOT EXISTS "runs_environment_status_idx" ON "runs" ("environment", "status") WHERE "environment" = 'sandboxed';
