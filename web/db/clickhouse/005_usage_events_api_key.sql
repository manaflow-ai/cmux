-- Attribute model and route usage to the long-lived CodeRouter API key when
-- one authenticated the request. The UUID is opaque and the secret never
-- enters ClickHouse. Existing rows remain null for route-token requests.
ALTER TABLE {db}.usage_events
  ADD COLUMN IF NOT EXISTS api_key_id Nullable(String)
  AFTER stack_user_id;

ALTER TABLE {db}.route_events
  ADD COLUMN IF NOT EXISTS api_key_id Nullable(String)
  AFTER stack_user_id;
