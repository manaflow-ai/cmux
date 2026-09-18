ALTER TABLE "device_tokens"
  ADD COLUMN "revoked_at" timestamp with time zone,
  ADD COLUMN "revoked_auth_fingerprint" text;
