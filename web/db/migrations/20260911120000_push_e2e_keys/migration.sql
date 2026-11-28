ALTER TABLE "device_tokens"
  ADD COLUMN "installation_id" text NOT NULL DEFAULT 'legacy',
  ADD COLUMN "push_key_id" text NOT NULL DEFAULT 'legacy',
  ADD COLUMN "push_public_key" text;

CREATE UNIQUE INDEX "device_tokens_bundle_installation_unique"
  ON "device_tokens" ("bundle_id", "installation_id")
  WHERE "installation_id" <> 'legacy';
