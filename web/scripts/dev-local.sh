#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load-dev-env.sh"

next_pid=""
started_db=0
cleanup_watcher_pid=""
db_watchdog_pid=""
dev_lock_file=""

dev_lock_key() {
  local branch slug
  branch="$(git -C "$ROOT_DIR/.." branch --show-current 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    branch="$(basename "$(cd "$ROOT_DIR/.." && pwd)")"
  fi
  slug="$(
    printf '%s' "$branch" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
      | cut -c1-48
  )"
  if [[ -z "$slug" ]]; then
    slug="worktree"
  fi
  printf '%s-dev-%s' "$slug" "$CMUX_PORT"
}

claim_dev_lock() {
  local lock_dir
  lock_dir="${TMPDIR:-/tmp}/cmux-web-dev"
  mkdir -p "$lock_dir"
  dev_lock_file="$lock_dir/$(dev_lock_key).pid"
  printf '%s\n' "$$" > "$dev_lock_file"
}

owns_dev_lock() {
  [[ -n "$dev_lock_file" && -f "$dev_lock_file" && "$(cat "$dev_lock_file" 2>/dev/null)" == "$$" ]]
}

stop_local_services() {
  if ! owns_dev_lock; then
    echo "cmux web dev: skipped local service stop because another dev process owns CMUX_PORT=$CMUX_PORT"
    return
  fi
  bash "$ROOT_DIR/scripts/db-local.sh" down >/dev/null 2>&1 || true
  echo "cmux web dev: stopped local Postgres for CMUX_PORT=$CMUX_PORT"
}

start_cleanup_watcher() {
  if [[ "${CMUX_DEV_STOP_DB_ON_EXIT:-1}" == "0" ]]; then
    return
  fi

  local parent_pid=$$
  (
    trap '' INT HUP
    while kill -0 "$parent_pid" >/dev/null 2>&1; do
      sleep 1
    done
    if owns_dev_lock; then
      bash "$ROOT_DIR/scripts/db-local.sh" down >/dev/null 2>&1 || true
    fi
  ) &
  cleanup_watcher_pid=$!
}

start_db_watchdog() {
  if [[ "${CMUX_DEV_WATCH_DB:-1}" == "0" ]]; then
    return
  fi

  local parent_pid=$$
  (
    trap '' INT HUP
    while kill -0 "$parent_pid" >/dev/null 2>&1; do
      if owns_dev_lock && ! bash "$ROOT_DIR/scripts/db-local.sh" ready >/dev/null 2>&1; then
        echo "cmux web dev: local Postgres unavailable; restarting for CMUX_PORT=$CMUX_PORT"
        if bash "$ROOT_DIR/scripts/db-local.sh" up >/dev/null 2>&1; then
          bunx drizzle-kit migrate --config "$ROOT_DIR/drizzle.config.ts" >/dev/null
        fi
      fi
      sleep 2
    done
  ) &
  db_watchdog_pid=$!
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n "$next_pid" ]] && kill -0 "$next_pid" >/dev/null 2>&1; then
    pkill -TERM -P "$next_pid" >/dev/null 2>&1 || true
    kill "$next_pid" >/dev/null 2>&1 || true
    wait "$next_pid" >/dev/null 2>&1 || true
  fi

  if [[ "$started_db" == "1" && "${CMUX_DEV_STOP_DB_ON_EXIT:-1}" != "0" ]]; then
    if [[ -n "$db_watchdog_pid" ]] && kill -0 "$db_watchdog_pid" >/dev/null 2>&1; then
      kill "$db_watchdog_pid" >/dev/null 2>&1 || true
      wait "$db_watchdog_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$cleanup_watcher_pid" ]] && kill -0 "$cleanup_watcher_pid" >/dev/null 2>&1; then
      kill "$cleanup_watcher_pid" >/dev/null 2>&1 || true
      wait "$cleanup_watcher_pid" >/dev/null 2>&1 || true
    fi
    stop_local_services
  fi

  if owns_dev_lock; then
    rm -f "$dev_lock_file"
  fi

  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${CMUX_DEV_START_DB:-1}" != "0" ]]; then
  started_db=1
  claim_dev_lock
  start_cleanup_watcher
  bash "$ROOT_DIR/scripts/db-local.sh" up >/dev/null
  bunx drizzle-kit migrate --config "$ROOT_DIR/drizzle.config.ts"
  start_db_watchdog
fi

redacted_database_url="postgres://${CMUX_DB_USER}:<redacted>@localhost:${CMUX_DB_PORT}/${CMUX_DB_NAME}"
cat <<EOF
cmux web dev
  CMUX_PORT=$CMUX_PORT
  CMUX_VM_API_BASE_URL=$CMUX_VM_API_BASE_URL
  DATABASE_URL=$redacted_database_url
  CMUX_WEB_SECRET_ENV_FILE=$CMUX_WEB_SECRET_ENV_FILE
  CMUX_WEB_EXTRA_SECRET_ENV_FILE=${CMUX_WEB_EXTRA_SECRET_ENV_FILE:-}
EOF

next dev --port "$CMUX_PORT" &
next_pid=$!

set +e
wait "$next_pid"
status=$?
set -e
next_pid=""
exit "$status"
