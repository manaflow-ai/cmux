DO $$ BEGIN
  ALTER TABLE "huge_blue_attach_tokens"
    ADD CONSTRAINT "huge_blue_attach_tokens_runtime_id_persistent_workspaces_id_fk"
    FOREIGN KEY ("runtime_id") REFERENCES "persistent_workspaces" ("id") ON DELETE CASCADE;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
