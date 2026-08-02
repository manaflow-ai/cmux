#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CMUX_CAPTURE_XCODEBUILD_ARGS"
printf '%s\n' "${TEST_RUNNER_CMUX_TEST_PROCESS:-<unset>}" >> "$CMUX_CAPTURE_TEST_RUNNER_ENV"
sleep 10
SH
chmod +x "$TMP_DIR/xcodebuild"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/xcodebuild-args.log" \
CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/test-runner-env.log" \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=0.1 \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/output.log" 2>&1
status=$?
set -e

if [ "$status" -ne 124 ]; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: expected wrapper to exit with final timeout status 124, got $status"
  exit 1
fi

if ! grep -Fq "Retrying app-host xcodebuild after 0.1s idle timeout (attempt 1/2)" "$TMP_DIR/output.log"; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: wrapper did not retry after idle timeout"
  exit 1
fi

timeout_count="$(grep -Fc "Idle timed out after 0.1s" "$TMP_DIR/output.log")"
if [ "$timeout_count" -ne 2 ]; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: expected two timed-out attempts, got $timeout_count"
  exit 1
fi

invocation_count="$(grep -cx 'test' "$TMP_DIR/xcodebuild-args.log" || true)"
runner_marker_count="$(grep -cx '1' "$TMP_DIR/test-runner-env.log" || true)"
if [ "$runner_marker_count" -eq 0 ] || [ "$runner_marker_count" -ne "$invocation_count" ]; then
  cat "$TMP_DIR/test-runner-env.log"
  echo "FAIL: expected every app-host launch to receive TEST_RUNNER_CMUX_TEST_PROCESS=1"
  exit 1
fi

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
attempt=0
if [ -f "$CMUX_CAPTURE_XCODEBUILD_ATTEMPT" ]; then
  attempt="$(<"$CMUX_CAPTURE_XCODEBUILD_ATTEMPT")"
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$CMUX_CAPTURE_XCODEBUILD_ATTEMPT"
if [ "$attempt" -eq 1 ]; then
  echo "The test runner crashed before establishing connection: cmux DEV at <external symbol>"
  exit 65
fi
echo "SocketControlServer: Listening on /tmp/cmux-debug-test.sock"
SH
chmod +x "$TMP_DIR/xcodebuild"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_CAPTURE_XCODEBUILD_ATTEMPT="$TMP_DIR/startup-crash-attempt.log" \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/startup-crash-output.log" 2>&1
status=$?
set -e

if [ "$status" -ne 0 ]; then
  cat "$TMP_DIR/startup-crash-output.log"
  echo "FAIL: expected wrapper to recover from a pre-bootstrap test-runner crash, got $status"
  exit 1
fi

if ! grep -Fq "Retrying app-host xcodebuild after test runner startup crash (attempt 1/2)" "$TMP_DIR/startup-crash-output.log"; then
  cat "$TMP_DIR/startup-crash-output.log"
  echo "FAIL: wrapper did not retry after a pre-bootstrap test-runner crash"
  exit 1
fi

if [ "$(<"$TMP_DIR/startup-crash-attempt.log")" -ne 2 ]; then
  cat "$TMP_DIR/startup-crash-attempt.log"
  echo "FAIL: expected startup crash recovery on the second attempt"
  exit 1
fi

echo "PASS: app-host xcodebuild wrapper retries transient startup failures"
