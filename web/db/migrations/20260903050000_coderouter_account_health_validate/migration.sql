-- Validate the replacement separately. Keep the old constraint in place until
-- this succeeds, then swap names in the same migration.
ALTER TABLE "coderouter_claude_accounts"
  VALIDATE CONSTRAINT "coderouter_claude_accounts_state_check_v2";
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts" DROP CONSTRAINT "coderouter_claude_accounts_state_check";
--> statement-breakpoint
ALTER TABLE "coderouter_claude_accounts"
  RENAME CONSTRAINT "coderouter_claude_accounts_state_check_v2" TO "coderouter_claude_accounts_state_check";
