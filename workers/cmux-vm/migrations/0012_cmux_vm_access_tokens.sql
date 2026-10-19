-- contract: adds tenant-scoped access token metadata and indexes without changing existing tables
-- cx-b4h.23: tenant-owned end-user access tokens. The signed token is never stored.
CREATE TABLE cmux_vm.access_tokens (
  id text PRIMARY KEY,
  tenant_id text NOT NULL,
  principal text NOT NULL,
  vm_ids text[] NOT NULL CHECK (cardinality(vm_ids) BETWEEN 1 AND 50),
  scopes text[] NOT NULL CHECK (cardinality(scopes) BETWEEN 1 AND 6),
  linux_user text NOT NULL,
  expires_at timestamptz NOT NULL,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  provider_identity_id text
);

CREATE INDEX access_tokens_tenant_created_idx
  ON cmux_vm.access_tokens (tenant_id, created_at DESC, id DESC);

CREATE INDEX access_tokens_expiry_identity_idx
  ON cmux_vm.access_tokens (expires_at)
  WHERE provider_identity_id IS NOT NULL;

-- The operator grants SELECT, INSERT and UPDATE to the Worker role alongside
-- the other cmux_vm tables.
