-- contract: widens signed-request purposes for provider-free server identity; old writes remain valid
-- Rehearse and apply before deployment; grant the Worker SELECT, INSERT and UPDATE
-- on the new table through the existing operator role workflow. Old readers and
-- writers keep using mesh_devices, which is unchanged. Roll back code first;
-- retain these additive rows and the wider replay check during rollback.
-- The migration runner commits this file and its version once, atomically.
-- A new table is explicit so its indexes cannot silently lock an existing table.
CREATE TABLE cmux_vm.mesh_overlay_servers (
  device_cmux_id text PRIMARY KEY,
  tenant_id text NOT NULL,
  mesh_cmux_id text NOT NULL,
  name text NOT NULL,
  wg_public_key text NOT NULL,
  install_public_key text NOT NULL,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL,
  revoked_at timestamptz NULL
);
CREATE UNIQUE INDEX mesh_overlay_servers_wg_live_idx
  ON cmux_vm.mesh_overlay_servers (tenant_id, mesh_cmux_id, wg_public_key) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX mesh_overlay_servers_install_live_idx
  ON cmux_vm.mesh_overlay_servers (tenant_id, mesh_cmux_id, install_public_key) WHERE revoked_at IS NULL;
ALTER TABLE cmux_vm.mesh_signed_requests
  DROP CONSTRAINT IF EXISTS mesh_signed_requests_purpose_v2_check,
  DROP CONSTRAINT IF EXISTS mesh_signed_requests_purpose_v3_check,
  ADD CONSTRAINT mesh_signed_requests_purpose_v2_check
    CHECK (purpose IN ('enroll', 'rotate-key', 'peers', 'tunnel', 'address', 'overlay-policy', 'enroll-overlay-server', 'overlay-server-policy', 'revoke-overlay-server')),
  ADD CONSTRAINT mesh_signed_requests_purpose_v3_check
    CHECK (purpose IN ('enroll', 'rotate-key', 'peers', 'tunnel', 'address', 'overlay-policy', 'enroll-overlay-server', 'overlay-server-policy', 'revoke-overlay-server'));
