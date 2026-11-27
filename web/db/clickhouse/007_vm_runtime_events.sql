-- Cloud VM metering (plans/cmux-next/cloud-metering-DESIGN.md). One row per
-- start or stop of a runtime interval. Postgres `cloud_vm_runtime_intervals`
-- records each interval in the same transaction as the VM status change; the
-- vm-metering cron copies them here. Paused time is never inside an interval.
--
-- Idempotency: `event_id` is `<interval id>:start` or `<interval id>:stop`, so a
-- replayed sync writes the same key again. ReplacingMergeTree keeps the row with
-- the highest `version` per (stack_user_id, vm_id, event_id). A stop's version
-- is (2^53 - stop time in ms), so the earliest proven stop wins: a reconcile
-- stop observed at the provider beats a later Postgres stop, never the reverse.
-- Partitioned by the interval's start month, never the event's time, so the two
-- rows of one key always share a partition and can merge. Readers do not rely
-- on merges: vm_runtime_intervals deduplicates with argMax at query time.
-- No TTL: these rows back invoices.

CREATE TABLE IF NOT EXISTS {db}.vm_runtime_events (
  event_id String,
  event_type LowCardinality(String),
  event_time DateTime64(3, 'UTC'),
  interval_id String,
  interval_started_at DateTime64(3, 'UTC'),
  vm_id String,
  stack_user_id String,
  team_id String,
  plan_id LowCardinality(String),
  provider LowCardinality(String),
  vcpus UInt16,
  memory_mb UInt32,
  source LowCardinality(String),
  version UInt64,
  recorded_at DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(interval_started_at)
ORDER BY (stack_user_id, vm_id, event_id);

CREATE VIEW IF NOT EXISTS {db}.vm_runtime_intervals AS
SELECT
  interval_id,
  any(vm_id) AS vm_id,
  any(stack_user_id) AS stack_user_id,
  any(team_id) AS team_id,
  any(plan_id) AS plan_id,
  any(provider) AS provider,
  max(vcpus) AS vcpus,
  max(memory_mb) AS memory_mb,
  minIf(event_time, event_type = 'start') AS started_at,
  if(countIf(event_type = 'stop') > 0, minIf(event_time, event_type = 'stop'), NULL) AS ended_at,
  anyIf(source, event_type = 'stop') AS stop_source
FROM (
  SELECT
    event_id,
    argMax(event_type, version) AS event_type,
    argMax(event_time, version) AS event_time,
    argMax(interval_id, version) AS interval_id,
    stack_user_id,
    vm_id,
    argMax(team_id, version) AS team_id,
    argMax(plan_id, version) AS plan_id,
    argMax(provider, version) AS provider,
    argMax(vcpus, version) AS vcpus,
    argMax(memory_mb, version) AS memory_mb,
    argMax(source, version) AS source
  FROM {db}.vm_runtime_events
  GROUP BY stack_user_id, vm_id, event_id
)
GROUP BY interval_id
HAVING countIf(event_type = 'start') > 0;
