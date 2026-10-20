-- Per-request origin inside a machine: the cmux-tui workspace and terminal
-- (surface) whose environment launched the agent, from the x-cmux-workspace-id
-- and x-cmux-surface-id headers. Empty when the agent ran outside a cmux-tui
-- terminal or before the guest config carried the headers. Applied per
-- database like 001; ADD COLUMN IF NOT EXISTS keeps re-runs idempotent.

ALTER TABLE {db}.usage_events
  ADD COLUMN IF NOT EXISTS workspace_id String DEFAULT '';

ALTER TABLE {db}.usage_events
  ADD COLUMN IF NOT EXISTS surface_id String DEFAULT '';
