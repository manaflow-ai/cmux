-- cmux VM S3a: the source of a snapshot, a label index, and audit rows for
-- API keys. Inside the cmux_vm schema: one nullable column on
-- cmux_vm.resources and two indexes (additive), and one widened CHECK on
-- cmux_vm.audit_log.cmux_id so API key ids (vmk_) can be audited; the new
-- check accepts every value the old one did. Nothing is dropped. Idempotency
-- keys live in the per-tenant ledger (Durable Object), not here. Applied by an
-- operator (staging rehearsal first), never by the Worker. Needs 0001 and 0002.
-- API key management also needs table grants; see workers/cmux-vm/README.md.

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

-- Audit rows name VMs, snapshots and API keys by public id.
ALTER TABLE cmux_vm.audit_log DROP CONSTRAINT IF EXISTS audit_log_cmux_id_check;
ALTER TABLE cmux_vm.audit_log ADD CONSTRAINT audit_log_cmux_id_check
  CHECK (cmux_id IS NULL OR cmux_id ~ '^(vm|snap|vmk)_[0-9a-hjkmnp-tv-z]{26}$');
