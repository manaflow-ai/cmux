#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
count_file="${CMUX_TEST_ATTEMPT_COUNT_FILE:?}"
attempt=1
if [ -f "$count_file" ]; then
  attempt="$(( $(cat "$count_file") + 1 ))"
fi
printf '%s' "$attempt" > "$count_file"
if [ "$attempt" -eq 1 ]; then
  echo '✘ Test stalePermission recorded an issue: Expectation failed'
  echo 'Failed to establish communication with the test runner'
  exit 1
fi
echo 'SocketControlServer: Listening on /tmp/cmux-test.sock'
exit 0
SH
chmod +x "$TMP_DIR/xcodebuild"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_APP_HOST_TEST_LOCK_ACTIVE=1 \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=3 \
CMUX_TEST_ATTEMPT_COUNT_FILE="$TMP_DIR/attempt-count" \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/output.log" 2>&1
status=$?
set -e

if [ "$status" -eq 0 ]; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: a real Swift Testing assertion was hidden by an infrastructure retry"
  exit 1
fi

if [ "$(cat "$TMP_DIR/attempt-count")" -ne 1 ]; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: assertion failures must stop after the first attempt"
  exit 1
fi

if grep -Fq "Retrying app-host xcodebuild" "$TMP_DIR/output.log"; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: wrapper retried an attempt containing a real assertion failure"
  exit 1
fi

echo "PASS: app-host wrapper propagates real assertion failures"
