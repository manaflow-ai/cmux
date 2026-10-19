-- phase: expand
-- Daytona lifecycle webhook delivery ids (cx-b4h.22). A delivery is inserted only
-- after the event has been resolved and recorded, so provider retries can retry a
-- failed delivery. The Worker role needs SELECT, INSERT and UPDATE on this table.
CREATE TABLE IF NOT EXISTS cmux_vm.daytona_webhook_deliveries (
  message_id text PRIMARY KEY CHECK (char_length(message_id) BETWEEN 1 AND 256),
  event_type text NOT NULL CHECK (event_type ~ '^[a-z_]{1,40}(\.[a-z_]{1,40})+$'),
  processed_at timestamptz NOT NULL DEFAULT now()
);
