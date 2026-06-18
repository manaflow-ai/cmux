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
# MACHINE with a machine-local mutex. atomic mkdir is the lock (portable; no
# util-linux flock dependency on macOS). The lock dir lives on local disk, so
# different machines use different locks and cross-machine parallelism is kept.
lock_dir="${CMUX_APP_HOST_TEST_LOCK_DIR:-${TMPDIR:-/tmp}/cmux-app-host-test.lock}"
lock_wait_seconds="${CMUX_APP_HOST_TEST_LOCK_WAIT_SECONDS:-3600}"
# Fallback only: break a lock whose owner pid is missing/unreadable once it is
# older than this. The PRIMARY staleness signal is owner-process liveness below,
# so an actively-running test of ANY duration is never broken.
lock_orphan_seconds="${CMUX_APP_HOST_TEST_LOCK_ORPHAN_SECONDS:-3600}"
lock_held=0
release_test_lock() { [ "$lock_held" = "1" ] && rm -rf "$lock_dir" 2>/dev/null || true; }
trap release_test_lock EXIT
waited=0
while :; do
  # Ownership is proven ONLY by creating the dir ourselves (atomic mkdir).
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" >"$lock_dir/owner.pid" 2>/dev/null || true
    lock_held=1
    echo "Holding app-host test lock: ${lock_dir} (pid $$)"
    break
  fi
  # Break the lock only when its owner process is genuinely gone, never on a
  # wall-clock guess: a long but live xcodebuild must keep its lock.
  owner_pid="$(cat "$lock_dir/owner.pid" 2>/dev/null || true)"
  case "$owner_pid" in
    ''|*[!0-9]*)
      # No readable numeric owner pid (lock just created, or corrupt): fall back
      # to an absolute age cap so a wedged lock cannot block the runner forever.
      lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || echo 0) ))
      if [ "$lock_age" -ge "$lock_orphan_seconds" ]; then
        echo "WARN: breaking app-host test lock ${lock_dir}; no owner pid, age ${lock_age}s" >&2
        rm -rf "$lock_dir" 2>/dev/null || true
        continue
      fi
      ;;
    *)
      if ! kill -0 "$owner_pid" 2>/dev/null; then
        echo "WARN: breaking app-host test lock ${lock_dir}; owner pid ${owner_pid} is gone" >&2
        rm -rf "$lock_dir" 2>/dev/null || true
        continue
      fi
      ;;
  esac
  if [ "$waited" -ge "$lock_wait_seconds" ]; then
    # Never run a second GUI test host on this Mac. A live owner held the lock
    # past the cap, so fail loudly (re-runnable) rather than run unlocked and
    # recreate the testmanagerd contention this lock exists to prevent.
    echo "FAIL: app-host test lock ${lock_dir} still held by live owner pid ${owner_pid:-unknown} after ${lock_wait_seconds}s; refusing to run a second GUI test host on this Mac (re-run the job)" >&2
    exit 1
  fi
  [ "$waited" = "0" ] && echo "Waiting for app-host test lock ${lock_dir} (owner pid ${owner_pid:-unknown} holds this Mac)..."
  sleep 5
  waited=$(( waited + 5 ))
done

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
