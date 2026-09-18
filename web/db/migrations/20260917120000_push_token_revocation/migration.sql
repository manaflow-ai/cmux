ALTER TABLE "device_tokens"
  ADD COLUMN "revoked_at" timestamp with time zone,
  ADD COLUMN "delivery_started_at" timestamp with time zone;

CREATE TABLE "device_token_revocations" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "device_token" text NOT NULL,
  "bundle_id" text NOT NULL,
  "auth_session_fingerprint" text NOT NULL,
  "revoked_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "device_token_revocations_session_unique"
  ON "device_token_revocations" ("user_id", "device_token", "bundle_id", "auth_session_fingerprint");
--> statement-breakpoint
CREATE INDEX "device_token_revocations_lookup_idx"
  ON "device_token_revocations" ("user_id", "device_token", "bundle_id");
