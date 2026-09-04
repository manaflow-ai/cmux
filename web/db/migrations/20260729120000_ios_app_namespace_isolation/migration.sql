ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "client_namespace" text NOT NULL DEFAULT 'legacy';

ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_client_namespace_check"
  CHECK ("client_namespace" ~ '^[A-Za-z0-9._:-]{1,255}$');

ALTER TABLE "iroh_registration_challenges"
  ADD COLUMN "client_namespace" text NOT NULL DEFAULT 'legacy';

ALTER TABLE "iroh_registration_challenges"
  ADD CONSTRAINT "iroh_registration_challenges_client_namespace_check"
  CHECK ("client_namespace" ~ '^[A-Za-z0-9._:-]{1,255}$');

DROP INDEX "iroh_endpoint_bindings_active_slot_unique";

CREATE UNIQUE INDEX "iroh_endpoint_bindings_active_slot_unique"
  ON "iroh_endpoint_bindings"
    ("user_id", "client_namespace", "device_uuid", "tag")
  WHERE "revoked_at" IS NULL;

CREATE INDEX "device_tokens_user_bundle_idx"
  ON "device_tokens" ("user_id", "bundle_id");

DROP INDEX "device_tokens_device_token_unique";

CREATE UNIQUE INDEX "device_tokens_bundle_token_unique"
  ON "device_tokens" ("bundle_id", "device_token");
