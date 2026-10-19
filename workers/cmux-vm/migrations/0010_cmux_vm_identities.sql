-- Freestyle-compatible identities and grants. Additive only; the worker never
-- runs DDL. Identity rows use the same tenant ownership table as VMs.
ALTER TABLE cmux_vm.resources DROP CONSTRAINT IF EXISTS resources_cmux_id_check;
ALTER TABLE cmux_vm.resources ADD CONSTRAINT resources_cmux_id_check
  CHECK (cmux_id ~ '^(vm|snap|idn)_[0-9a-hjkmnp-tv-z]{26}$');
ALTER TABLE cmux_vm.resources DROP CONSTRAINT IF EXISTS resources_kind_check;
ALTER TABLE cmux_vm.resources ADD CONSTRAINT resources_kind_check
  CHECK (kind IN ('vm', 'snapshot', 'mesh', 'device', 'tunnel', 'identity'));
ALTER TABLE cmux_vm.resources DROP CONSTRAINT IF EXISTS resources_kind_cmux_id_check;
ALTER TABLE cmux_vm.resources ADD CONSTRAINT resources_kind_cmux_id_check
  CHECK ((kind = 'vm' AND cmux_id LIKE 'vm\_%')
      OR (kind = 'snapshot' AND cmux_id LIKE 'snap\_%')
      OR (kind = 'identity' AND cmux_id LIKE 'idn\_%')
      OR (kind IN ('mesh', 'device', 'tunnel')));

CREATE TABLE IF NOT EXISTS cmux_vm.identity_vm_grants (
  id                 text PRIMARY KEY CHECK (id ~ '^vmp-[A-Za-z0-9-]+$'),
  tenant_id          text NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  identity_cmux_id   text NOT NULL CHECK (identity_cmux_id LIKE 'idn\_%'),
  vm_cmux_id         text NOT NULL CHECK (vm_cmux_id LIKE 'vm\_%'),
  upstream_id        text NOT NULL CHECK (char_length(upstream_id) BETWEEN 1 AND 256),
  allowed_linux_users text[] NULL,
  granted_at         timestamptz NOT NULL DEFAULT now(),
  granted_by         text NOT NULL CHECK (char_length(granted_by) BETWEEN 1 AND 160),
  revoked_at         timestamptz NULL,
  UNIQUE (tenant_id, identity_cmux_id, vm_cmux_id)
);
CREATE INDEX IF NOT EXISTS identity_vm_grants_identity_idx
  ON cmux_vm.identity_vm_grants (tenant_id, identity_cmux_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS identity_vm_grants_vm_idx
  ON cmux_vm.identity_vm_grants (tenant_id, vm_cmux_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS cmux_vm.identity_tokens (
  id                 text PRIMARY KEY CHECK (id ~ '^tok-[A-Za-z0-9-]+$'),
  tenant_id          text NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  identity_cmux_id   text NOT NULL CHECK (identity_cmux_id LIKE 'idn\_%'),
  token_hash         text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  created_at         timestamptz NOT NULL DEFAULT now(),
  revoked_at         timestamptz NULL
);
CREATE INDEX IF NOT EXISTS identity_tokens_identity_idx
  ON cmux_vm.identity_tokens (tenant_id, identity_cmux_id) WHERE revoked_at IS NULL;
