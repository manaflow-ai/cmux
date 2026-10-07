-- cmux VM S3a: the source of a snapshot, and a label index. Additive only,
-- inside the cmux_vm schema: one nullable column on cmux_vm.resources and two
-- indexes; nothing existing is altered or dropped. Idempotency keys live in
-- the per-tenant ledger (Durable Object), not here. Applied by an operator
-- (staging rehearsal first), never by the Worker. Needs 0001 and 0002.

-- The public id of the resource this one was made from (a snapshot's source
-- VM), so listing snapshots by source never asks the provider.
ALTER TABLE cmux_vm.resources
  ADD COLUMN IF NOT EXISTS parent_cmux_id text NULL
    CHECK (parent_cmux_id IS NULL OR parent_cmux_id ~ '^(vm|snap)_[0-9a-hjkmnp-tv-z]{26}$');

CREATE INDEX IF NOT EXISTS resources_tenant_kind_parent_idx
  ON cmux_vm.resources (tenant_id, kind, parent_cmux_id, created_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS resources_labels_idx
  ON cmux_vm.resources USING gin (labels)
  WHERE deleted_at IS NULL;
