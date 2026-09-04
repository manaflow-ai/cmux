-- Credential health for coderouter accounts: Claude accounts count
-- consecutive credential rejections and become "broken" instead of cooling
-- down forever, both stores remember when the owner was emailed about a
-- broken or expired account (one email per account, ever), and Claude
-- accounts carry a fingerprint so the same secret cannot be added twice.
-- Add the replacement as NOT VALID while the old constraint is still active.
-- A follow-up migration validates it with a weaker lock after this change.
ALTER TABLE "coderouter_claude_accounts" ADD CONSTRAINT "coderouter_claude_accounts_state_check_v2"
  CHECK ("state" IN ('active', 'disabled', 'broken')) NOT VALID;
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "consecutive_failures" integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "broken_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "broken_notified_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "fingerprint" text DEFAULT '' NOT NULL;
--> statement-breakpoint
-- Drizzle runs this file in one transaction, so CREATE INDEX CONCURRENTLY
-- would fail. The table was created in the immediately preceding migration
-- and contains at most the migrated single row per team at this point, so the
-- atomic build is short. A future high-volume backfill should use a separately
-- scheduled concurrent rebuild.
CREATE UNIQUE INDEX "coderouter_claude_accounts_fingerprint_idx"
  ON "coderouter_claude_accounts" ("team_id", "fingerprint") WHERE "fingerprint" <> '';
--> statement-breakpoint
ALTER TABLE "coderouter_accounts" ADD COLUMN "broken_notified_at" timestamp with time zone;
