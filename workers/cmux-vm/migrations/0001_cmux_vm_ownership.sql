-- cmux VM: ownership and API key tables. Additive only: two new tables with
-- the cmux_vm_ prefix and their indexes; nothing existing is altered or dropped.
-- Applied by an operator (staging rehearsal first), never by the Worker.

CREATE TABLE IF NOT EXISTS cmux_vm_resources (
  cmux_id     text        PRIMARY KEY CHECK (cmux_id ~ '^(vm|snap)_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id   text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  kind        text        NOT NULL CHECK (kind IN ('vm', 'snapshot')),
  upstream_id text        NOT NULL CHECK (char_length(upstream_id) BETWEEN 1 AND 256),
  created_by  text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz NULL,
  CHECK ((kind = 'vm' AND cmux_id LIKE 'vm\_%') OR (kind = 'snapshot' AND cmux_id LIKE 'snap\_%'))
);

-- One public id per upstream resource, so an upstream id can never be claimed twice.
CREATE UNIQUE INDEX IF NOT EXISTS cmux_vm_resources_kind_upstream_key
  ON cmux_vm_resources (kind, upstream_id);

-- List endpoints read the caller's tenant only.
CREATE INDEX IF NOT EXISTS cmux_vm_resources_tenant_kind_created_idx
  ON cmux_vm_resources (tenant_id, kind, created_at DESC)
  WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS cmux_vm_api_keys (
  id                 text        PRIMARY KEY CHECK (id ~ '^vmk_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id          text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  name               text        NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  -- Lowercase hex SHA-256 of the full key. The key itself is never stored.
  key_hash           text        NOT NULL UNIQUE CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  scopes             text[]      NOT NULL,
  -- NULL: every resource of the tenant. Otherwise only these public ids.
  resource_allowlist text[]      NULL,
  created_by         text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at         timestamptz NOT NULL DEFAULT now(),
  expires_at         timestamptz NULL,
  revoked_at         timestamptz NULL
);

CREATE INDEX IF NOT EXISTS cmux_vm_api_keys_tenant_idx
  ON cmux_vm_api_keys (tenant_id, created_at DESC);
