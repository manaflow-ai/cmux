-- cmux VM S3a: the source of a snapshot, and idempotency keys for snapshot
-- creates. Additive only, inside the cmux_vm schema: one nullable column on
-- cmux_vm.resources, one new table, and their indexes; nothing existing is
-- altered or dropped. Applied by an operator (staging rehearsal first), never
-- by the Worker. Needs 0001 and 0002.

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

-- Idempotency-Key header on snapshot creates, per tenant. A pending row marks
-- a request in flight; a completed row holds the public response to replay.
-- Rows past expires_at, and pending rows past their lease, are replaced.
CREATE TABLE IF NOT EXISTS cmux_vm.idempotency_keys (
  tenant_id       text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  key             text        NOT NULL CHECK (char_length(key) BETWEEN 1 AND 255),
  fingerprint     text        NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
  state           text        NOT NULL CHECK (state IN ('pending', 'completed')),
  response_status integer     NULL,
  response_body   text        NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  PRIMARY KEY (tenant_id, key),
  CHECK ((state = 'pending') = (response_status IS NULL AND response_body IS NULL))
);
