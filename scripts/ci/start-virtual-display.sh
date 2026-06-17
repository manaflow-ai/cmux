#!/usr/bin/env bash
set -euo pipefail

label="${1:-ci}"
safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '-')"
runner_temp="${RUNNER_TEMP:-/tmp}"
env_file="${GITHUB_ENV:-}"
attempts="${CMUX_VDISPLAY_START_ATTEMPTS:-3}"

if [ -z "$env_file" ]; then
  echo "GITHUB_ENV is required so cleanup can find the virtual display helper" >&2
  exit 1
fi

append_env() {
  printf '%s=%s\n' "$1" "$2" >> "$env_file"
}

cleanup_attempt() {
  if [ -n "${vdisplay_pid:-}" ]; then
    kill "$vdisplay_pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      kill -0 "$vdisplay_pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
    vdisplay_pid=""
  fi
  if [ -n "${CMUX_VDISPLAY_LOCK_TOKEN:-}" ]; then
    scripts/ci/virtual-display-lock.sh release || true
  fi
}

success=0
trap 'if [ "$success" != "1" ]; then cleanup_attempt; fi' EXIT

case "$attempts" in
  ''|*[!0-9]*)
    echo "CMUX_VDISPLAY_START_ATTEMPTS must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "$attempts" -lt 1 ]; then
  echo "CMUX_VDISPLAY_START_ATTEMPTS must be a positive integer" >&2
  exit 2
fi

for attempt in $(seq 1 "$attempts"); do
  helper_path="$runner_temp/create-virtual-display-${safe_label}-${attempt}"
  ready_path="$runner_temp/cmux-vdisplay-${safe_label}-${attempt}.ready"
  display_id_path="$runner_temp/cmux-vdisplay-${safe_label}-${attempt}.id"
  log_path="$runner_temp/cmux-vdisplay-${safe_label}-${attempt}.log"
  vdisplay_pid=""

  rm -f "$helper_path" "$ready_path" "$display_id_path" "$log_path"

  lock_env="$(scripts/ci/virtual-display-lock.sh acquire)"
  eval "$lock_env"
  export CMUX_VDISPLAY_LOCK_DIR CMUX_VDISPLAY_LOCK_TOKEN

  clang -framework Foundation -framework CoreGraphics \
    -o "$helper_path" scripts/create-virtual-display.m

  "$helper_path" \
    --ready-path "$ready_path" \
    --display-id-path "$display_id_path" \
    >"$log_path" 2>&1 &
  vdisplay_pid=$!
  scripts/ci/virtual-display-lock.sh set-owner "$vdisplay_pid"

  for _ in $(seq 1 100); do
    if [ -s "$ready_path" ] && [ -s "$display_id_path" ]; then
      append_env CMUX_VDISPLAY_LOCK_DIR "$CMUX_VDISPLAY_LOCK_DIR"
      append_env CMUX_VDISPLAY_LOCK_TOKEN "$CMUX_VDISPLAY_LOCK_TOKEN"
      append_env VDISPLAY_PID "$vdisplay_pid"
      append_env VDISPLAY_HELPER_PATH "$helper_path"
      append_env VDISPLAY_READY "$ready_path"
      append_env VDISPLAY_ID_PATH "$display_id_path"
      append_env VDISPLAY_LOG "$log_path"
      echo "Virtual display ready: $(tr -d '\n' < "$display_id_path")"
      cat "$log_path"
      success=1
      exit 0
    fi

    if ! kill -0 "$vdisplay_pid" 2>/dev/null; then
      echo "Virtual display helper exited before readiness on attempt $attempt" >&2
      cat "$log_path" >&2 || true
      break
    fi

    sleep 0.1
  done

  echo "Virtual display not ready on attempt $attempt" >&2
  cat "$log_path" >&2 || true
  cleanup_attempt
  if [ "$attempt" -lt "$attempts" ]; then
    sleep 5
  fi
done

echo "Failed to create virtual display after $attempts attempts" >&2
exit 1
