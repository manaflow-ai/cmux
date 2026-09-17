ALTER TABLE "iroh_endpoint_bindings"
  ADD COLUMN "path_hints_next_expiry" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  DROP CONSTRAINT "iroh_endpoint_bindings_identity_generation_check";
--> statement-breakpoint
ALTER TABLE "iroh_endpoint_bindings"
  ADD CONSTRAINT "iroh_endpoint_bindings_identity_generation_check"
  CHECK ("identity_generation" between 1 and 2147483647);
--> statement-breakpoint
ALTER TABLE "iroh_registration_challenges"
  DROP CONSTRAINT "iroh_registration_challenges_identity_generation_check";
--> statement-breakpoint
ALTER TABLE "iroh_registration_challenges"
  ADD CONSTRAINT "iroh_registration_challenges_identity_generation_check"
  CHECK ("identity_generation" between 1 and 2147483647);
--> statement-breakpoint
UPDATE "iroh_endpoint_bindings" AS binding
SET "path_hints_next_expiry" = (
  SELECT min((hint ->> 'expires_at')::timestamptz)
  FROM jsonb_array_elements(binding."path_hints") AS hints(hint)
  WHERE jsonb_typeof(hint) = 'object'
    AND jsonb_typeof(hint -> 'expires_at') = 'string'
    AND (hint ->> 'expires_at') ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
)
WHERE binding."revoked_at" IS NULL
  AND binding."path_hints" <> '[]'::jsonb;
--> statement-breakpoint
UPDATE "iroh_endpoint_bindings"
SET "path_hints" = '[]'::jsonb,
    "path_hints_next_expiry" = NULL
WHERE "revoked_at" IS NOT NULL
  AND "path_hints" <> '[]'::jsonb;
--> statement-breakpoint
CREATE INDEX "iroh_endpoint_bindings_path_hints_expiry_idx"
  ON "iroh_endpoint_bindings" USING btree ("path_hints_next_expiry", "id")
  WHERE "revoked_at" IS NULL AND "path_hints_next_expiry" IS NOT NULL;
--> statement-breakpoint
CREATE INDEX "iroh_endpoint_bindings_revoked_hints_idx"
  ON "iroh_endpoint_bindings" USING btree ("revoked_at", "id")
  WHERE "revoked_at" IS NOT NULL AND "path_hints_next_expiry" IS NOT NULL;
--> statement-breakpoint
DROP INDEX "iroh_registration_challenges_expires_idx";
--> statement-breakpoint
CREATE INDEX "iroh_registration_challenges_expires_idx"
  ON "iroh_registration_challenges" USING btree ("expires_at", "id");
--> statement-breakpoint
CREATE INDEX "iroh_registration_challenges_consumed_idx"
  ON "iroh_registration_challenges" USING btree ("consumed_at", "id")
  WHERE "consumed_at" IS NOT NULL;
--> statement-breakpoint
CREATE INDEX "iroh_registration_challenges_user_expires_idx"
  ON "iroh_registration_challenges" USING btree ("user_id", "expires_at", "id");
--> statement-breakpoint
CREATE INDEX "iroh_registration_challenges_user_consumed_idx"
  ON "iroh_registration_challenges" USING btree ("user_id", "consumed_at", "id")
  WHERE "consumed_at" IS NOT NULL;
--> statement-breakpoint
CREATE INDEX "iroh_pair_grant_issuances_expires_idx"
  ON "iroh_pair_grant_issuances" USING btree ("expires_at", "id");
--> statement-breakpoint
CREATE INDEX "iroh_pair_grant_issuances_user_expires_idx"
  ON "iroh_pair_grant_issuances" USING btree ("user_id", "expires_at", "id");
--> statement-breakpoint
CREATE INDEX "iroh_relay_token_issuances_requested_idx"
  ON "iroh_relay_token_issuances" USING btree ("requested_at", "id");
--> statement-breakpoint
DROP INDEX "iroh_relay_token_issuances_user_requested_idx";
--> statement-breakpoint
CREATE INDEX "iroh_relay_token_issuances_user_requested_idx"
  ON "iroh_relay_token_issuances" USING btree ("user_id", "requested_at", "id");
