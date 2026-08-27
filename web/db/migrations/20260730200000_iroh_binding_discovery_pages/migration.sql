CREATE INDEX "iroh_endpoint_bindings_user_active_page_idx"
  ON "iroh_endpoint_bindings" ("user_id", "id")
  WHERE "revoked_at" IS NULL;
