-- Preserve the authenticated Stack user on failed and successful route rows.
-- Nullable is required for auth rejects that happen before route-token
-- identity exists. Usage rows remain the token source of truth.
ALTER TABLE {db}.route_events
  ADD COLUMN IF NOT EXISTS stack_user_id Nullable(String)
  AFTER team_id;
