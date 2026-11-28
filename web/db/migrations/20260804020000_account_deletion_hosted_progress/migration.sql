ALTER TABLE "account_deletion_tombstones"
  ADD COLUMN "hosted_subrouter_deleted_team_ids" jsonb NOT NULL DEFAULT '[]'::jsonb;
