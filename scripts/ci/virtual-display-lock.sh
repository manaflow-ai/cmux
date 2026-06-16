#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-}"
if [ $# -gt 0 ]; then
  shift
fi

LOCK_DIR="${CMUX_VDISPLAY_LOCK_DIR:-/tmp/cmux-ci-virtual-display.lock}"
LOCK_TIMEOUT_SECONDS="${CMUX_VDISPLAY_LOCK_TIMEOUT_SECONDS:-600}"
LOCK_STALE_SECONDS="${CMUX_VDISPLAY_LOCK_STALE_SECONDS:-1800}"
LOCK_OWNERLESS_STALE_SECONDS="${CMUX_VDISPLAY_LOCK_OWNERLESS_STALE_SECONDS:-$LOCK_TIMEOUT_SECONDS}"
LOCK_POLL_SECONDS="${CMUX_VDISPLAY_LOCK_POLL_SECONDS:-2}"

usage() {
  cat >&2 <<'EOF'
usage: virtual-display-lock.sh acquire|set-owner <pid>|release

Coordinates host-global CGVirtualDisplay use between concurrent self-hosted
macOS jobs. acquire prints CMUX_VDISPLAY_LOCK_DIR and
CMUX_VDISPLAY_LOCK_TOKEN shell assignments on stdout.
EOF
}

now_seconds() {
  date +%s
}

validate_lock_dir() {
  case "$LOCK_DIR" in
    /tmp/cmux-*.lock)
      return 0
      ;;
  esac
  if [ -n "${RUNNER_TEMP:-}" ]; then
    case "$LOCK_DIR" in
      "$RUNNER_TEMP"/*)
        return 0
        ;;
    esac
  fi
  case "$LOCK_DIR" in
    *)
      echo "Refusing unsafe virtual display lock path: $LOCK_DIR" >&2
      exit 1
      ;;
  esac
}

new_token() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    printf '%s-%s\n' "$$" "$(now_seconds)"
  fi
}

write_metadata() {
  local token="$1"
  {
    printf 'created_at=%s\n' "$(now_seconds)"
    printf 'token=%s\n' "$token"
    printf 'host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'run_id=%s\n' "${GITHUB_RUN_ID:-unknown}"
    printf 'job=%s\n' "${GITHUB_JOB:-unknown}"
    printf 'pid=%s\n' "$$"
  } > "$LOCK_DIR/metadata"
  printf '%s\n' "$token" > "$LOCK_DIR/token"
}

lock_created_at() {
  if [ -f "$LOCK_DIR/metadata" ]; then
    awk -F= '$1 == "created_at" { print $2; exit }' "$LOCK_DIR/metadata" 2>/dev/null || true
  fi
}

owner_is_alive() {
  local owner_pid=""
  if [ -f "$LOCK_DIR/owner_pid" ]; then
    owner_pid="$(cat "$LOCK_DIR/owner_pid" 2>/dev/null || true)"
  fi
  case "$owner_pid" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  if kill -0 "$owner_pid" 2>/dev/null; then
    return 0
  fi
  ps -p "$owner_pid" >/dev/null 2>&1
}

ownerless_stale_seconds() {
  local stale_seconds="$LOCK_OWNERLESS_STALE_SECONDS"
  case "$stale_seconds" in
    ''|*[!0-9]*)
      stale_seconds="$LOCK_TIMEOUT_SECONDS"
      ;;
  esac
  if [ "$stale_seconds" -gt "$LOCK_TIMEOUT_SECONDS" ]; then
    stale_seconds="$LOCK_TIMEOUT_SECONDS"
  fi
  printf '%s\n' "$stale_seconds"
}

remove_stale_lock_if_needed() {
  local now created age owner_pid stale_seconds
  owner_pid=""
  if [ -f "$LOCK_DIR/owner_pid" ]; then
    owner_pid="$(cat "$LOCK_DIR/owner_pid" 2>/dev/null || true)"
  fi
  case "$owner_pid" in
    ''|*[!0-9]*)
      ;;
    *)
      if owner_is_alive; then
        return 1
      fi
      echo "Removing virtual display lock at $LOCK_DIR with dead owner PID $owner_pid" >&2
      rm -rf "$LOCK_DIR"
      return 0
      ;;
  esac

  now="$(now_seconds)"
  created="$(lock_created_at)"
  if [ -z "$created" ]; then
    created="$(stat -f %m "$LOCK_DIR" 2>/dev/null || printf '%s\n' "$now")"
  fi
  age=$((now - created))
  stale_seconds="$(ownerless_stale_seconds)"
  if [ "$age" -lt "$stale_seconds" ]; then
    return 1
  fi
  echo "Removing ownerless stale virtual display lock at $LOCK_DIR (age ${age}s)" >&2
  rm -rf "$LOCK_DIR"
  return 0
}

acquire() {
  validate_lock_dir
  mkdir -p "$(dirname "$LOCK_DIR")"

  local token start now elapsed
  token="$(new_token)"
  start="$(now_seconds)"

  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      write_metadata "$token"
      printf 'CMUX_VDISPLAY_LOCK_DIR=%q\n' "$LOCK_DIR"
      printf 'CMUX_VDISPLAY_LOCK_TOKEN=%q\n' "$token"
      exit 0
    fi

    remove_stale_lock_if_needed && continue

    now="$(now_seconds)"
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$LOCK_TIMEOUT_SECONDS" ]; then
      echo "Timed out waiting for virtual display lock at $LOCK_DIR after ${elapsed}s" >&2
      if [ -f "$LOCK_DIR/metadata" ]; then
        echo "--- virtual display lock holder ---" >&2
        cat "$LOCK_DIR/metadata" >&2 || true
      fi
      exit 1
    fi

    echo "Waiting for virtual display lock at $LOCK_DIR (${elapsed}s elapsed)" >&2
    sleep "$LOCK_POLL_SECONDS"
  done
}

require_token_match() {
  validate_lock_dir
  local token="${CMUX_VDISPLAY_LOCK_TOKEN:-}"
  if [ -z "$token" ]; then
    echo "CMUX_VDISPLAY_LOCK_TOKEN is required for $COMMAND" >&2
    exit 1
  fi
  if [ ! -d "$LOCK_DIR" ]; then
    echo "Virtual display lock is already absent: $LOCK_DIR" >&2
    return 1
  fi
  if [ "$(cat "$LOCK_DIR/token" 2>/dev/null || true)" != "$token" ]; then
    echo "Virtual display lock token mismatch for $LOCK_DIR; not modifying it" >&2
    return 1
  fi
  return 0
}

set_owner() {
  local owner_pid="${1:-}"
  if [ -z "$owner_pid" ]; then
    echo "set-owner requires a PID" >&2
    exit 1
  fi
  require_token_match || exit 1
  printf '%s\n' "$owner_pid" > "$LOCK_DIR/owner_pid"
}

release() {
  require_token_match || exit 0
  rm -rf "$LOCK_DIR"
}

case "$COMMAND" in
  acquire)
    acquire
    ;;
  set-owner)
    set_owner "${1:-}"
    ;;
  release)
    release
    ;;
  *)
    usage
    exit 2
    ;;
esac
