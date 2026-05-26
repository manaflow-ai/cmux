#!/usr/bin/env bash
set -euo pipefail

schema_only=0
if [[ "${1:-}" == "--schema-only" ]]; then
  schema_only=1
  shift
fi

web_dir="${1:-.}"
if [[ ! -f "$web_dir/package.json" && -f "$web_dir/web/package.json" ]]; then
  web_dir="$web_dir/web"
fi

if [[ ! -f "$web_dir/package.json" ]]; then
  echo "Could not find web/package.json. Pass the web directory as the first argument." >&2
  exit 2
fi

cd "$web_dir"

required_scripts=(
  db:check
  db:migrate
  db:migrate:aws-rds-iam
  db:test
)

for script_name in "${required_scripts[@]}"; do
  if ! bun -e "const p=require('./package.json'); if (!p.scripts?.[process.argv[1]]) process.exit(1)" "$script_name"; then
    echo "missing package script: $script_name" >&2
    exit 1
  fi
done

if [[ ! -f drizzle.config.ts ]]; then
  echo "missing drizzle.config.ts" >&2
  exit 1
fi

if [[ ! -d db/migrations ]]; then
  echo "missing db/migrations" >&2
  exit 1
fi

echo "checking drizzle migration metadata"
bun run db:check

if [[ "$schema_only" == "1" ]]; then
  echo "schema-only preflight passed"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for local migration test preflight" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker is not running" >&2
  exit 1
fi

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  fi
  docker ps --format '{{.Ports}}' | grep -Eq "($port->|:$port->)" >/dev/null 2>&1
}

choose_cmux_port() {
  local dev_offset="${CMUX_DB_PORT_OFFSET:-10000}"
  local test_offset="${CMUX_TEST_DB_PORT_OFFSET:-30000}"
  local max_offset="$test_offset"
  if (( dev_offset > max_offset )); then
    max_offset="$dev_offset"
  fi
  local min_candidate=30000
  local max_candidate=$((65535 - max_offset))
  if (( max_candidate < min_candidate )); then
    echo "invalid CMUX_*_PORT_OFFSET values for port selection" >&2
    exit 1
  fi
  if [[ -n "${CMUX_MIGRATION_PREFLIGHT_PORT:-}" ]]; then
    printf '%s\n' "$CMUX_MIGRATION_PREFLIGHT_PORT"
    return
  fi
  for _ in $(seq 1 100); do
    local candidate=$((min_candidate + RANDOM % (max_candidate - min_candidate + 1)))
    local dev_db=$((candidate + dev_offset))
    local test_db=$((candidate + test_offset))
    if ! port_in_use "$candidate" && ! port_in_use "$dev_db" && ! port_in_use "$test_db"; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  echo "failed to find free CMUX_PORT for migration preflight" >&2
  exit 1
}

export CMUX_PORT="$(choose_cmux_port)"
echo "using isolated CMUX_PORT=$CMUX_PORT for migration preflight"

cleanup_test_db() {
  env \
    CMUX_DB_KIND=test \
    CMUX_DB_PORT_OFFSET="${CMUX_TEST_DB_PORT_OFFSET:-30000}" \
    CMUX_DB_NAME="${CMUX_TEST_DB_NAME:-cmux_test}" \
    bash scripts/db-local.sh down >/dev/null 2>&1 || true
  docker volume ls --format '{{.Name}}' \
    | grep -E "^cmux-postgres-.*-test-${CMUX_PORT}$" \
    | xargs -r docker volume rm >/dev/null 2>&1 || true
}

trap cleanup_test_db EXIT

echo "running isolated local database migration tests"
bun run db:test

cleanup_test_db
trap - EXIT

echo "cloud vm migration preflight passed"
