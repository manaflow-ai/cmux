-- The iroh transport is removed. Drop the trust-broker and relay-fleet tables;
-- dependents (FKs onto iroh_endpoint_bindings) go first so the drops are
-- order-safe without CASCADE.
DROP TABLE IF EXISTS "iroh_relay_token_issuances";
--> statement-breakpoint
DROP TABLE IF EXISTS "iroh_pair_grant_issuances";
--> statement-breakpoint
DROP TABLE IF EXISTS "iroh_registration_challenges";
--> statement-breakpoint
DROP TABLE IF EXISTS "iroh_endpoint_bindings";
--> statement-breakpoint
DROP TABLE IF EXISTS "iroh_account_security_states";
--> statement-breakpoint
DROP TABLE IF EXISTS "iroh_relay_preferences";
--> statement-breakpoint
DROP TABLE IF EXISTS "iroh_relay_catalog_state";
