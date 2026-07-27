ALTER TABLE "iroh_relay_token_issuances"
  DROP CONSTRAINT "iroh_relay_token_issuances_status_check";
--> statement-breakpoint
ALTER TABLE "iroh_relay_token_issuances"
  ADD CONSTRAINT "iroh_relay_token_issuances_status_check"
  CHECK ("status" in ('pending', 'succeeded', 'failed', 'expired')) NOT VALID;
