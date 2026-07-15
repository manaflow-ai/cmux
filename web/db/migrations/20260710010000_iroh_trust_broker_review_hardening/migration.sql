CREATE INDEX "iroh_endpoint_bindings_user_idx"
  ON "iroh_endpoint_bindings" USING btree ("user_id");
--> statement-breakpoint
CREATE INDEX "iroh_endpoint_bindings_user_revoked_idx"
  ON "iroh_endpoint_bindings" USING btree ("user_id", "revoked_at", "id")
  WHERE "revoked_at" IS NOT NULL;
--> statement-breakpoint
CREATE INDEX "iroh_pair_grant_issuances_initiator_idx"
  ON "iroh_pair_grant_issuances" USING btree ("initiator_binding_id", "expires_at");
