-- Indexes for bounded cleanup of time-limited team state.
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "pending_challenges_expiry_idx" ON "pending_challenges" ("expires_at");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "device_proof_replays_global_expiry_idx" ON "device_proof_replays" ("expires_at");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "user_authority_expiry_idx" ON "user_authority" ("expires_at");
--> statement-breakpoint
UPDATE "team_meta" SET "schema_version" = 7 WHERE "id" = 1;
