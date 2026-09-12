CREATE TABLE IF NOT EXISTS cmux_workspace_snapshots (
  team_id text NOT NULL,
  vm_id text NOT NULL,
  generation text NOT NULL,
  revision bigint NOT NULL CHECK (revision >= 0),
  snapshot jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, vm_id)
);
CREATE TABLE IF NOT EXISTS cmux_workspace_events (
  id bigserial PRIMARY KEY,
  team_id text NOT NULL,
  vm_id text NOT NULL,
  generation text NOT NULL,
  revision bigint NOT NULL CHECK (revision >= 0),
  snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (team_id, vm_id, generation, revision)
);
CREATE INDEX IF NOT EXISTS cmux_workspace_events_team_created_idx
  ON cmux_workspace_events (team_id, created_at);
