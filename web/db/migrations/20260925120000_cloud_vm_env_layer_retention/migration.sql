-- Retention checks correlate env-layer snapshots with their deletion-intent
-- ledger events. Keep that lookup bounded as the lifecycle ledger grows.
CREATE INDEX IF NOT EXISTS "cloud_vm_usage_events_snapshot_lifecycle_idx"
  ON "cloud_vm_usage_events" ("provider", "event_type", (("metadata"->>'snapshotId')));
