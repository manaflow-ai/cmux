-- cmux VM: snapshot listing columns, the audit log and idempotency keys.
-- Additive only, inside the cmux_vm schema from 0001: three nullable columns
-- on cmux_vm.resources, two new tables and their indexes. Nothing is altered in place or
-- dropped. Applied by an operator (staging rehearsal first), never by the Worker.

-- What a list endpoint shows without asking the provider: the public id of the
-- resource this one was made from (a snapshot's source VM) and a display name.
ALTER TABLE cmux_vm.resources
  ADD COLUMN IF NOT EXISTS parent_cmux_id text NULL
    CHECK (parent_cmux_id IS NULL OR parent_cmux_id ~ '^(vm|snap)_[0-9a-hjkmnp-tv-z]{26}$');
ALTER TABLE cmux_vm.resources
  ADD COLUMN IF NOT EXISTS display_name text NULL
    CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 100);

-- Caller-chosen key/value labels (at most 16), filterable with containment.
ALTER TABLE cmux_vm.resources
  ADD COLUMN IF NOT EXISTS labels jsonb NULL
    CHECK (labels IS NULL OR jsonb_typeof(labels) = 'object');

CREATE INDEX IF NOT EXISTS resources_labels_idx
  ON cmux_vm.resources USING gin (labels)
  WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS resources_tenant_kind_parent_idx
  ON cmux_vm.resources (tenant_id, kind, parent_cmux_id, created_at DESC)
  WHERE deleted_at IS NULL;

-- One row per mutation attempt that reached the provider. No secrets, no
-- command bodies, no provider ids.
CREATE TABLE IF NOT EXISTS cmux_vm.audit_log (
  id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id   text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  actor       text        NOT NULL CHECK (char_length(actor) BETWEEN 1 AND 160),
  action      text        NOT NULL CHECK (action ~ '^[a-z]+\.[a-z]+$'),
  resource_id text        NOT NULL CHECK (resource_id ~ '^(vm|snap)_[0-9a-hjkmnp-tv-z]{26}$'),
  outcome     text        NOT NULL CHECK (outcome IN ('succeeded', 'failed')),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_log_tenant_created_idx
  ON cmux_vm.audit_log (tenant_id, created_at DESC);

-- Idempotency-Key header on creates, per tenant. A pending row marks a request
-- in flight; a completed row holds the public response to replay. Rows past
-- expires_at are ignored and replaced.
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
