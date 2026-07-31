ALTER TABLE "iroh_account_security_states"
  ADD COLUMN "route_revision" bigint DEFAULT 0 NOT NULL;
--> statement-breakpoint
ALTER TABLE "iroh_account_security_states"
  ADD CONSTRAINT "iroh_account_security_states_route_revision_check"
  CHECK ("route_revision" >= 0) NOT VALID;
