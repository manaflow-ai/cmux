CREATE TABLE cloud_diagnostic_events (
  user_id text NOT NULL,
  event_id uuid NOT NULL,
  payload jsonb NOT NULL,
  payload_hash text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  lease_id uuid,
  attempts integer NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, event_id)
);
CREATE INDEX cloud_diagnostic_events_pending_idx ON cloud_diagnostic_events (next_attempt_at) WHERE delivered_at IS NULL;
CREATE INDEX cloud_diagnostic_events_retention_idx ON cloud_diagnostic_events (received_at);

CREATE TABLE cloud_diagnostic_budgets (
  user_id text NOT NULL,
  minute bigint NOT NULL,
  bytes integer NOT NULL,
  PRIMARY KEY (user_id, minute)
);

CREATE TABLE cloud_operation_steps (
  user_id text NOT NULL,
  operation_id uuid NOT NULL,
  step_id uuid NOT NULL,
  phase text NOT NULL,
  outcome text NOT NULL,
  started_at timestamptz NOT NULL,
  ended_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '1 day',
  PRIMARY KEY (user_id, operation_id, step_id)
);
CREATE INDEX cloud_operation_steps_expiry_idx ON cloud_operation_steps (expires_at);
