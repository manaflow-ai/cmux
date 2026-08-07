CREATE INDEX "iroh_endpoint_bindings_active_pairable_mac_scope_idx"
ON "iroh_endpoint_bindings" USING btree ("user_id", lower("tag"), "id")
WHERE "revoked_at" is null and "platform" = 'mac' and "pairing_enabled" = true;
--> statement-breakpoint
CREATE INDEX "iroh_endpoint_bindings_active_ios_scope_idx"
ON "iroh_endpoint_bindings" USING btree ("user_id", "id")
WHERE "revoked_at" is null and "platform" = 'ios';
