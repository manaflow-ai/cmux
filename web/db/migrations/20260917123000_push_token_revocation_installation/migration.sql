ALTER TABLE "device_token_revocations"
  ADD COLUMN "installation_id" text NOT NULL DEFAULT 'legacy';
--> statement-breakpoint
DROP INDEX "device_token_revocations_session_unique";
--> statement-breakpoint
CREATE UNIQUE INDEX "device_token_revocations_session_unique"
  ON "device_token_revocations" (
    "user_id",
    "device_token",
    "installation_id",
    "bundle_id",
    "auth_session_fingerprint"
  );
--> statement-breakpoint
CREATE INDEX "device_token_revocations_installation_lookup_idx"
  ON "device_token_revocations" ("user_id", "installation_id", "bundle_id");
