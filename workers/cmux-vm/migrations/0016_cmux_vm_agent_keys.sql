-- Agent keys and per-VM client sessions. Additive only.
--
-- An agent key is an ordinary API key row with agent_labels set: it reaches
-- only VMs carrying every one of those labels (always cmux.agent=<its id>),
-- has a live-VM and USD/h budget, and its VMs are deleted by the reaper once it
-- expires or is revoked (agent_cleaned_at records that the reaper finished).
-- The API validates the new columns; old rows keep them NULL.
--
-- A client session is one provider identity with one VM grant and one access
-- token. Only the provider identity id is stored, never the token; deleting the
-- identity revokes the token and the grant.
--
-- Apply through the versioned migration runner before deploying code; grant
-- the Worker SELECT, INSERT and UPDATE on cmux_vm.vm_client_sessions (the
-- api_keys grants already cover the new columns). Roll back code first.
ALTER TABLE cmux_vm.api_keys ADD COLUMN IF NOT EXISTS agent_labels jsonb NULL;
ALTER TABLE cmux_vm.api_keys ADD COLUMN IF NOT EXISTS agent_max_vms integer NULL;
ALTER TABLE cmux_vm.api_keys ADD COLUMN IF NOT EXISTS agent_max_usd_per_hour numeric(10, 4) NULL;
ALTER TABLE cmux_vm.api_keys ADD COLUMN IF NOT EXISTS agent_cleaned_at timestamptz NULL;

CREATE TABLE IF NOT EXISTS cmux_vm.vm_client_sessions (
  id                   text        PRIMARY KEY CHECK (id ~ '^vcs_[0-9a-hjkmnp-tv-z]{26}$'),
  tenant_id            text        NOT NULL CHECK (char_length(tenant_id) BETWEEN 1 AND 128),
  vm_cmux_id           text        NOT NULL,
  -- The provider identity that holds the grant and the token. Server-side only.
  upstream_identity_id text        NOT NULL UNIQUE CHECK (char_length(upstream_identity_id) BETWEEN 1 AND 200),
  linux_user           text        NOT NULL CHECK (linux_user ~ '^[a-z_][a-z0-9_-]{0,31}$'),
  created_by           text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 160),
  created_at           timestamptz NOT NULL DEFAULT now(),
  revoked_at           timestamptz NULL
);
