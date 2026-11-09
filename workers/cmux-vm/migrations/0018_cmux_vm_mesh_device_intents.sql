-- Enroll intents: a caller's own id for one device enroll, its revocation tombstone, and every create attempt made
-- under it. Additive only.
--
-- mesh_device_intents has one row per (tenant, mesh, intent id). An enroll with an intentId claims the row (pointing
-- device_cmux_id at its attempt) before it creates the provider tunnel, and commits it in the same statement that
-- inserts the mesh_devices row. A revoke sets revoked_at on the same row, so the row lock orders them: a revoke that
-- lands first makes the commit insert nothing, and one that lands after sees the committed device. The revoke's
-- authorization is in its own write: it changes the row only for the claimant (created_by) or a tenant admin, carrying
-- the row's labels, and for a caller confined to resources only when every attempt's device (attempt_device_ids) is
-- in its allowlist. The same predicate gates every other write a caller makes to an existing row: a new claim, and
-- ending a finished or stale claim to reconcile its attempts. A tombstone (revoked_at) lasts 7 days.
--
-- mesh_device_intent_attempts keeps one row per create attempt, never overwritten by a later one. An attempt is
-- resolved (resolved_at) only once nothing it made can be live: it never sent its provider create, the provider
-- refused that create outright, or its tunnel's delete was confirmed (also when found at the provider by its slug
-- after a lost reply), or the provider has no tunnel at its slug and either answered its create or was sent it more
-- than 15 minutes ago. sent_at is set, under the attempt's row lock, just before the provider create; an unsent
-- attempt is resolved by setting resolved_at under the same lock, so it can never send after that. A revoke answers
-- its final 200 only when every attempt of the intent is resolved.
--
-- Apply through the versioned migration runner before deploying code; grant the Worker SELECT, INSERT and UPDATE on
-- both tables through the operator role workflow. Roll back code first.
CREATE TABLE IF NOT EXISTS cmux_vm.mesh_device_intents (
  tenant_id      text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  mesh_cmux_id   text        NOT NULL CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  intent_id      text        NOT NULL CHECK (intent_id ~ '^[A-Za-z0-9._:~-]{1,128}$'),
  -- The current claim's attempt; NULL when no create holds the intent (or for a tombstone written before any enroll).
  device_cmux_id text        NULL CHECK (device_cmux_id IS NULL OR device_cmux_id ~ '^dev_[0-9a-hjkmnp-tv-z]{26}$'),
  -- The device of every attempt ever made under the intent, for the revoke's resource allowlist check.
  attempt_device_ids text[]  NOT NULL DEFAULT '{}'::text[] CHECK (cardinality(attempt_device_ids) <= 1000),
  created_by     text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  -- The claimant's required labels: its device and tunnel rows carry them, and a revoker must.
  labels         jsonb       NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(labels) = 'object' AND octet_length(labels::text) <= 4096),
  created_at     timestamptz NOT NULL,
  committed_at   timestamptz NULL,
  revoked_at     timestamptz NULL,
  PRIMARY KEY (tenant_id, mesh_cmux_id, intent_id)
);

CREATE TABLE IF NOT EXISTS cmux_vm.mesh_device_intent_attempts (
  tenant_id      text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  mesh_cmux_id   text        NOT NULL CHECK (mesh_cmux_id ~ '^mesh_[0-9a-hjkmnp-tv-z]{26}$'),
  intent_id      text        NOT NULL CHECK (intent_id ~ '^[A-Za-z0-9._:~-]{1,128}$'),
  device_cmux_id text        NOT NULL CHECK (device_cmux_id ~ '^dev_[0-9a-hjkmnp-tv-z]{26}$'),
  tunnel_cmux_id text        NOT NULL CHECK (tunnel_cmux_id ~ '^tun_[0-9a-hjkmnp-tv-z]{26}$'),
  created_at     timestamptz NOT NULL,
  -- Just before the provider create was sent. NULL: it never was, and once resolved never will be.
  sent_at        timestamptz NULL,
  -- The provider's tunnel id, once its create answered with one.
  upstream_id    text        NULL CHECK (upstream_id IS NULL OR char_length(upstream_id) BETWEEN 1 AND 256),
  -- The provider answered the create (a tunnel or an error): the request was processed and cannot land later.
  answered_at    timestamptz NULL,
  -- The create that made this attempt returned (whatever its outcome): no commit can come from it any more.
  finished_at    timestamptz NULL,
  resolved_at    timestamptz NULL,
  PRIMARY KEY (tenant_id, mesh_cmux_id, intent_id, device_cmux_id)
);

-- The index a device's delete uses to revoke its intent is 0019 (built concurrently).
