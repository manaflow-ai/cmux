-- Record how long a request waited for upstream capacity and how many times,
-- so a capacity storm shows up as route latency rather than failures. Rows
-- written before this column existed read as zero.
ALTER TABLE {db}.route_events
  ADD COLUMN IF NOT EXISTS held_ms UInt32 DEFAULT 0
  AFTER duration_ms;

ALTER TABLE {db}.route_events
  ADD COLUMN IF NOT EXISTS hold_count UInt16 DEFAULT 0
  AFTER held_ms;
