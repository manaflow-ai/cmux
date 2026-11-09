-- Enroll intents: a caller's own id for one device enroll, and its revocation tombstone. Additive only.
--
-- One row per (tenant, mesh, intent id). An enroll with an intentId claims the
-- row before it creates the provider tunnel, and commits it in the same
-- statement that inserts the mesh_devices row. A revoke sets revoked_at on the
-- same row, so the row lock orders them: a revoke that lands first makes the
-- commit insert nothing (the enroll then deletes its tunnel), and one that
-- lands after sees the committed device and deletes it. No time cutoff is
-- involved. A tombstone (revoked_at) lasts 7 days; a claim left uncommitted
-- for 10 minutes (a create that died) may be taken again, and the stale
-- create's commit then matches nothing.
--
-- Apply through the versioned migration runner before deploying code; grant
-- the Worker SELECT, INSERT and UPDATE on cmux_vm.mesh_device_intents through
-- the operator role workflow. Roll back code first.
CREATE TABLE IF NOT EXISTS cmux_vm.mesh_device_intents (
  tenant_id      text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  mesh_cmux_id   text        NOT NULL CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  intent_id      text        NOT NULL CHECK (intent_id ~ '^[A-Za-z0-9._:~-]{1,128}$'),
  -- The device the current claim creates; NULL for a released claim or a tombstone written before any enroll.
  device_cmux_id text        NULL CHECK (device_cmux_id IS NULL OR device_cmux_id ~ '^dev_[0-9a-hjkmnp-tv-z]{26}$'),
  created_by     text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at     timestamptz NOT NULL,
  committed_at   timestamptz NULL,
  revoked_at     timestamptz NULL,
  PRIMARY KEY (tenant_id, mesh_cmux_id, intent_id)
);

-- The index a device's delete uses to revoke its intent is 0019 (built concurrently).
