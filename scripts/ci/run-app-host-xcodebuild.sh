#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <xcodebuild args...>" >&2
  exit 2
fi
log_dir="${RUNNER_TEMP:-/tmp}"
log_stem="${log_dir%/}/cmux-app-host-xcodebuild-${CMUX_TAG:-untagged}"
max_attempts="${CMUX_APP_HOST_XCODEBUILD_ATTEMPTS:-3}"
export CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS="${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS:-${CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_SECONDS:-300}}"
echo "App-host xcodebuild idle timeout: ${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS}s, attempts: ${max_attempts}"

# Principled serialization (the actual fix; the retry below is only a backstop).
# Invariant: a GUI test host owns the Mac's single login session + testmanagerd
# while it runs. Two hosts on one self-hosted Mac contend for that one session
# and drop the test-runner channel. Enforce one app-host test at a time PER
# MACHINE with a real kernel lock (fcntl.flock via app_host_test_lock.py): the
# kernel releases it automatically when the holder exits, even on crash, so there
# is no stale lock to detect and no recovery race. We re-exec ourselves under the
# lock holder, which inherits the held lock fd across exec and keeps it for this
# script's whole lifetime. Different machines use different local lock files, so
# cross-machine parallelism is preserved.
if [ -z "${CMUX_APP_HOST_TEST_LOCK_ACTIVE:-}" ]; then
  lock_file="${CMUX_APP_HOST_TEST_LOCK_FILE:-${TMPDIR:-/tmp}/cmux-app-host-test.lock}"
  lock_wait_seconds="${CMUX_APP_HOST_TEST_LOCK_WAIT_SECONDS:-3600}"
  export CMUX_APP_HOST_TEST_LOCK_ACTIVE=1
  exec python3 "$(dirname "$0")/app_host_test_lock.py" \
    "$lock_file" "$lock_wait_seconds" "$0" "$@"
fi

# Resolve a CI-scoped root so app-host cleanup targets every CI app-host on this
# Mac (this run AND orphans left by previous runs, which live under a different
# per-run DerivedData path), while never matching a human's tagged dev build
# outside the runner work area. Prefer RUNNER_TEMP (all CI DerivedData lives
# under it); fall back to this run's -derivedDataPath from the xcodebuild args.
derived_data_path=""
prev_arg=""
for arg in "$@"; do
  if [ "$prev_arg" = "-derivedDataPath" ]; then derived_data_path="$arg"; break; fi
  prev_arg="$arg"
done
ci_app_host_root="${RUNNER_TEMP:-${derived_data_path}}"
kill_stale_app_host() {
  # Kill app-host executables (matched by their .../Build/Products/.../cmux DEV
  # path) under the CI work root only. This catches a stale host orphaned by a
  # previous run under a different DerivedData path, without touching an
  # unrelated dev build outside the runner work area. If we cannot identify the
  # root, do nothing rather than risk an unrelated process.
  [ -n "$ci_app_host_root" ] && \
    pkill -f "${ci_app_host_root%/}/.*Build/Products/.*cmux DEV" 2>/dev/null || true
}

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  log_path="${log_stem}-attempt-${attempt}.log"
  : >"$log_path"
  # Self-hosted macOS runners reuse the GUI session. A stale "cmux DEV" app-host
  # left running by a prior job (or another job sharing the machine) contends for
  # the single foreground session and testmanagerd, a top cause of the "Failed to
  # establish communication with the test runner" flake. Start each attempt from
  # a clean slate.
  kill_stale_app_host
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
    elif grep -Fq 'The test runner hung before establishing connection.' "$log_path"; then
      retry_reason="XCTest startup hang"
    elif grep -Fq 'Failed to establish communication with the test runner' "$log_path"; then
      retry_reason="test runner communication failure"
    elif grep -Fq 'com.apple.testmanagerd.control was invalidated' "$log_path"; then
      retry_reason="testmanagerd connection invalidated"
    elif grep -Fq "Couldn't communicate with a helper application" "$log_path"; then
      retry_reason="test helper communication failure"
    fi

    if [ -n "$retry_reason" ] && [ "$attempt" -lt "$max_attempts" ]; then
      echo "Retrying app-host xcodebuild after ${retry_reason} (attempt $attempt/$max_attempts)" >&2
      kill_stale_app_host
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
