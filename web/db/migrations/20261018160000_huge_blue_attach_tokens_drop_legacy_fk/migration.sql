-- Attach tokens now belong to persistent_workspaces. Older staging snapshots
-- carried the aggregate runtime FK from the pre-split implementation; keep
-- the migration idempotent while removing that conflicting ownership edge.
ALTER TABLE "huge_blue_attach_tokens"
  DROP CONSTRAINT IF EXISTS "huge_blue_attach_tokens_runtime_id_fkey";
