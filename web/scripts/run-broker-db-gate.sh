#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

database_url="${DIRECT_DATABASE_URL:-${DATABASE_URL:-}}"
if [[ -z "$database_url" ]]; then
  echo "test:broker:db requires DIRECT_DATABASE_URL or DATABASE_URL for an isolated PostgreSQL database" >&2
  exit 2
fi

if [[ "${CMUX_BROKER_DB_ALLOW_PRODUCTION:-0}" != "1" && "$database_url" =~ (^|[?&])((branch|database|dbname)=)?(main|production)([/?&]|$) ]]; then
  echo "refusing broker DB tests against a production-looking database URL" >&2
  exit 2
fi

export DATABASE_URL="$database_url"
export DIRECT_DATABASE_URL="$database_url"
export CMUX_DB_TEST=1
export CMUX_DB_TEST_CONNECT_TIMEOUT="${CMUX_DB_TEST_CONNECT_TIMEOUT:-10 seconds}"
db_test_timeout_ms="${CMUX_DB_TEST_TIMEOUT_MS:-30000}"
if [[ ! "$db_test_timeout_ms" =~ ^[1-9][0-9]*$ ]]; then
  echo "CMUX_DB_TEST_TIMEOUT_MS must be a positive integer" >&2
  exit 2
fi

if [[ "${CMUX_BROKER_DB_MIGRATE:-1}" == "1" ]]; then
  bun "$ROOT_DIR/scripts/db-migrate.mjs"
fi

bun test --isolate --timeout="$db_test_timeout_ms" --max-concurrency=1 \
  tests/agent-broker-db-behavior.test.ts \
  tests/huge-blue-attach-db.test.ts \
  tests/remote-runtime-db-behavior.test.ts \
  tests/db-effect-runtime.test.ts \
  tests/hive-runtime-db-behavior.test.ts
