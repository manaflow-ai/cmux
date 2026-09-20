#!/usr/bin/env bash
set -u

run_diagnostics() {
  # Keep provider/network evidence in the job log without failing the original
  # operation. These commands are intentionally read-only and emit no tokens.
  echo "== network diagnostics (runner=${RUNNER_NAME:-unknown}) ==" >&2
  if command -v scutil >/dev/null 2>&1; then
    scutil --dns 2>&1 || true
  fi
  if command -v route >/dev/null 2>&1; then
    route -n get default 2>&1 || true
  fi
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>&1 || true
  fi
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name github.com 2>&1 || true
  fi
  if command -v curl >/dev/null 2>&1; then
    curl --connect-timeout 5 --max-time 10 --silent --show-error --head https://github.com/ 2>&1 || true
  fi
  echo "== end network diagnostics ==" >&2
}

terminate_tree() {
  local parent="$1"
  local child
  for child in $(pgrep -P "$parent" 2>/dev/null || true); do
    terminate_tree "$child"
  done
  kill -TERM "$parent" 2>/dev/null || true
}

# A provider diagnostic command can hang independently of curl's own deadline.
# Run the complete read-only probe behind a watchdog so a failed resolver
# attempt cannot consume the enclosing CI job timeout. The timeout is
# configurable for tests, while production callers retain the 60-second cap.
diagnostics_timeout="${CMUX_NETWORK_DIAGNOSTICS_TIMEOUT_SECONDS:-60}"
run_diagnostics &
diagnostics_pid=$!
(
  sleep "$diagnostics_timeout"
  if kill -0 "$diagnostics_pid" 2>/dev/null; then
    echo "::warning::network diagnostics exceeded ${diagnostics_timeout}s; terminating probes" >&2
    terminate_tree "$diagnostics_pid"
  fi
) &
watchdog_pid=$!

diagnostics_status=0
wait "$diagnostics_pid" || diagnostics_status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
exit "$diagnostics_status"
