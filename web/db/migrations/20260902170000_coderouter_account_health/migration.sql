-- Credential health for coderouter accounts: Claude accounts count
-- consecutive credential rejections and become "broken" instead of cooling
-- down forever, both stores remember when the owner was emailed about a
-- broken or expired account (one email per account, ever), and Claude
-- accounts carry a fingerprint so the same secret cannot be added twice.
ALTER TABLE "coderouter_claude_accounts" DROP CONSTRAINT "coderouter_claude_accounts_state_check";
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD CONSTRAINT "coderouter_claude_accounts_state_check"
  CHECK ("state" IN ('active', 'disabled', 'broken'));
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "consecutive_failures" integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "broken_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "broken_notified_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "fingerprint" text DEFAULT '' NOT NULL;
--> statement-breakpoint
CREATE UNIQUE INDEX "coderouter_claude_accounts_fingerprint_idx"
  ON "coderouter_claude_accounts" ("team_id", "fingerprint") WHERE "fingerprint" <> '';
--> statement-breakpoint
ALTER TABLE "coderouter_accounts" ADD COLUMN "broken_notified_at" timestamp with time zone;
