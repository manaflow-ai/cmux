-- Per-request upstream account attribution: which team account (Claude API
-- key, OAuth token, Bedrock credential) served a request. Empty for providers
-- without per-account routing rows (codex today). Applied per database like
-- 001; ADD COLUMN IF NOT EXISTS keeps re-runs idempotent.

ALTER TABLE {db}.usage_events
  ADD COLUMN IF NOT EXISTS upstream_account_id String DEFAULT '';

ALTER TABLE {db}.route_events
  ADD COLUMN IF NOT EXISTS upstream_account_id String DEFAULT '';
