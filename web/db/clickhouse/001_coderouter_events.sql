-- coderouter usage ledger and route health, one row per request.
-- Applied per database ({db} = coderouter for production, coderouter_dev for
-- preview and local dev) by scripts/clickhouse-migrate.ts. No prompt, output,
-- header, or credential ever lands here.

CREATE DATABASE IF NOT EXISTS {db};

CREATE TABLE IF NOT EXISTS {db}.usage_events (
  event_time DateTime64(3, 'UTC') CODEC(Delta, ZSTD),
  team_id String,
  stack_user_id String,
  vm_id Nullable(String),
  provider LowCardinality(String),
  upstream_kind LowCardinality(String),
  agent LowCardinality(String),
  model LowCardinality(String),
  input_tokens UInt64,
  cached_input_tokens UInt64,
  output_tokens UInt64,
  total_tokens UInt64,
  api_equivalent_usd Float64,
  priced UInt8,
  rate_card_version LowCardinality(String),
  request_id String,
  status UInt16
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (team_id, event_time)
TTL toDateTime(event_time) + INTERVAL 400 DAY;

CREATE TABLE IF NOT EXISTS {db}.route_events (
  event_time DateTime64(3, 'UTC') CODEC(Delta, ZSTD),
  team_id String,
  vm_id Nullable(String),
  provider LowCardinality(String),
  agent LowCardinality(String),
  outcome LowCardinality(String),
  failure_stage LowCardinality(String),
  status UInt16,
  attempt_count UInt8,
  refresh_retry_count UInt8,
  duration_ms UInt32,
  response_streamed UInt8,
  request_id String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (team_id, event_time)
TTL toDateTime(event_time) + INTERVAL 400 DAY;
