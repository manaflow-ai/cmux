#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <xcodebuild args...>" >&2
  exit 2
fi
log_dir="${RUNNER_TEMP:-/tmp}"
log_stem="${log_dir%/}/cmux-app-host-xcodebuild-${CMUX_TAG:-untagged}"
max_attempts="${CMUX_APP_HOST_XCODEBUILD_ATTEMPTS:-3}"
lock_dir="${CMUX_APP_HOST_XCODEBUILD_LOCK_DIR:-/tmp/cmux-ci-app-host-xcodebuild.lock}"
lock_timeout_seconds="${CMUX_APP_HOST_XCODEBUILD_LOCK_TIMEOUT_SECONDS:-2700}"
lock_poll_seconds="${CMUX_APP_HOST_XCODEBUILD_LOCK_POLL_SECONDS:-2}"
lock_token=""
export CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS="${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS:-${CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_SECONDS:-300}}"
echo "App-host xcodebuild idle timeout: ${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS}s, attempts: ${max_attempts}"

now_seconds() {
  date +%s
}

validate_lock_dir() {
  case "$lock_dir" in
    /tmp/cmux-*.lock)
      return 0
      ;;
  esac
  if [ -n "${RUNNER_TEMP:-}" ]; then
    case "$lock_dir" in
      "$RUNNER_TEMP"/*)
        return 0
        ;;
    esac
  fi
  echo "Refusing unsafe app-host xcodebuild lock path: $lock_dir" >&2
  exit 1
}

new_lock_token() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    printf '%s-%s\n' "$$" "$(now_seconds)"
  fi
}

write_lock_metadata() {
  local token="$1"
  {
    printf 'created_at=%s\n' "$(now_seconds)"
    printf 'token=%s\n' "$token"
    printf 'host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'run_id=%s\n' "${GITHUB_RUN_ID:-unknown}"
    printf 'job=%s\n' "${GITHUB_JOB:-unknown}"
    printf 'pid=%s\n' "$$"
  } > "$lock_dir/metadata"
  printf '%s\n' "$token" > "$lock_dir/token"
}

lock_owner_pid() {
  if [ -f "$lock_dir/metadata" ]; then
    awk -F= '$1 == "pid" { print $2; exit }' "$lock_dir/metadata" 2>/dev/null || true
  fi
}

remove_dead_owner_lock_if_needed() {
  local owner_pid
  owner_pid="$(lock_owner_pid)"
  case "$owner_pid" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  if kill -0 "$owner_pid" 2>/dev/null || ps -p "$owner_pid" >/dev/null 2>&1; then
    return 1
  fi
  echo "Removing app-host xcodebuild lock at $lock_dir with dead owner PID $owner_pid" >&2
  rm -rf "$lock_dir"
  return 0
}

acquire_lock() {
  validate_lock_dir
  mkdir -p "$(dirname "$lock_dir")"

  local start now elapsed
  lock_token="$(new_lock_token)"
  start="$(now_seconds)"

  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      write_lock_metadata "$lock_token"
      echo "Acquired app-host xcodebuild lock at $lock_dir"
      return 0
    fi

    remove_dead_owner_lock_if_needed && continue

    now="$(now_seconds)"
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$lock_timeout_seconds" ]; then
      echo "Timed out waiting for app-host xcodebuild lock at $lock_dir after ${elapsed}s" >&2
      if [ -f "$lock_dir/metadata" ]; then
        echo "--- app-host xcodebuild lock holder ---" >&2
        cat "$lock_dir/metadata" >&2 || true
      fi
      exit 1
    fi

    echo "Waiting for app-host xcodebuild lock at $lock_dir (${elapsed}s elapsed)" >&2
    sleep "$lock_poll_seconds"
  done
}

release_lock() {
  if [ -z "$lock_token" ] || [ ! -d "$lock_dir" ]; then
    return 0
  fi
  if [ "$(cat "$lock_dir/token" 2>/dev/null || true)" != "$lock_token" ]; then
    echo "App-host xcodebuild lock token mismatch for $lock_dir; not removing it" >&2
    return 0
  fi
  rm -rf "$lock_dir"
  lock_token=""
}

trap release_lock EXIT
acquire_lock

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  log_path="${log_stem}-attempt-${attempt}.log"
  : >"$log_path"
  set +e
  CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH="$log_path" \
    scripts/ci/xcodebuild_noninteractive.py xcodebuild "$@"
  status=$?
  set -e

  if grep -Fq 'path = "/tmp/cmux-debug.sock"' "$log_path"; then
    echo "FAIL: app-host used default debug socket instead of an XCTest-scoped socket" >&2
    exit 1
  fi

  if grep -Fq 'SocketControlServer: Listening on /tmp/cmux-debug.sock' "$log_path"; then
    echo "FAIL: app-host listener used default debug socket instead of an XCTest-scoped socket" >&2
    exit 1
  fi

  if [ "$status" -ne 0 ]; then
    retry_reason=""
    if [ "$status" -eq 124 ]; then
      retry_reason="${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS}s idle timeout"
    elif [ "$status" -eq 86 ]; then
      retry_reason="Swift crash prompt"
    elif grep -Fq 'The test runner hung before establishing connection.' "$log_path"; then
      retry_reason="XCTest startup hang"
    fi

    if [ -n "$retry_reason" ] && [ "$attempt" -lt "$max_attempts" ]; then
      echo "Retrying app-host xcodebuild after ${retry_reason} (attempt $attempt/$max_attempts)" >&2
      pkill -x "cmux DEV" || true
      attempt=$((attempt + 1))
      continue
    fi
    exit "$status"
  fi

  if ! grep -Eq 'SocketControlServer: Listening on |message = "socket.listener.start"' "$log_path"; then
    echo "FAIL: app-host xcodebuild output did not include socket listener evidence" >&2
    exit 1
  fi

  exit 0
done

exit 1
