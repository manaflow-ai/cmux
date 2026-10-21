-- Server-only invitations pin public keys and reserve an identity. Existing
-- gateway enrollment tables and signed-request purposes remain unchanged.
-- Apply through the versioned migration runner before deploying code; grant
-- the Worker SELECT, INSERT and UPDATE through the operator role workflow.
-- Roll back code first and retain these additive rows during rollback.
CREATE TABLE cmux_vm.mesh_overlay_server_codes (
  code_sha256 text PRIMARY KEY,
  tenant_id text NOT NULL,
  mesh_cmux_id text NOT NULL,
  device_cmux_id text NOT NULL,
  name text NOT NULL,
  wg_public_key text NOT NULL,
  install_public_key text NOT NULL,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at timestamptz NULL,
  burned_at timestamptz NULL,
  CHECK (expires_at > created_at)
);
CREATE INDEX mesh_overlay_server_codes_recent_idx
  ON cmux_vm.mesh_overlay_server_codes (tenant_id, mesh_cmux_id, created_at);
