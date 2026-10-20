ALTER TABLE "account_deletion_tombstones"
  ADD COLUMN "legacy_subrouter_retired_tenant_ids" jsonb NOT NULL DEFAULT '[]'::jsonb;
