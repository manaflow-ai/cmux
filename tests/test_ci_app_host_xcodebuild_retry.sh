#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
sleep 10
SH
chmod +x "$TMP_DIR/xcodebuild"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
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

if ! grep -Fq "Starting app-host xcodebuild attempt 2/2; log:" "$TMP_DIR/output.log"; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: wrapper did not print the second attempt boundary"
  exit 1
fi

timeout_count="$(grep -Fc "Idle timed out after 0.1s" "$TMP_DIR/output.log")"
if [ "$timeout_count" -ne 2 ]; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: expected two timed-out attempts, got $timeout_count"
  exit 1
fi

echo "PASS: app-host xcodebuild wrapper retries idle timeouts"

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Press space to interact, D to debug, or any other key to quit'
sleep 10
SH
chmod +x "$TMP_DIR/xcodebuild"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/crash-prompt-output.log" 2>&1
status=$?
set -e

if [ "$status" -ne 86 ]; then
  cat "$TMP_DIR/crash-prompt-output.log"
  echo "FAIL: expected wrapper to exit with final Swift crash prompt status 86, got $status"
  exit 1
fi

if ! grep -Fq "Retrying app-host xcodebuild after Swift crash prompt (attempt 1/2)" "$TMP_DIR/crash-prompt-output.log"; then
  cat "$TMP_DIR/crash-prompt-output.log"
  echo "FAIL: wrapper did not retry after Swift crash prompt"
  exit 1
fi

prompt_count="$(grep -Fc "Swift crash prompt detected; terminating noninteractive child" "$TMP_DIR/crash-prompt-output.log")"
if [ "$prompt_count" -ne 2 ]; then
  cat "$TMP_DIR/crash-prompt-output.log"
  echo "FAIL: expected two Swift crash prompt terminations, got $prompt_count"
  exit 1
fi

echo "PASS: app-host xcodebuild wrapper retries Swift crash prompts"

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'cmux DEV encountered an error (Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying Error: Test crashed with signal term before establishing connection.))'
exit 65
SH
chmod +x "$TMP_DIR/xcodebuild"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/bootstrap-output.log" 2>&1
status=$?
set -e

if [ "$status" -ne 65 ]; then
  cat "$TMP_DIR/bootstrap-output.log"
  echo "FAIL: expected wrapper to exit with final XCTest bootstrap status 65, got $status"
  exit 1
fi

if ! grep -Fq "Retrying app-host xcodebuild after XCTest bootstrap exit (attempt 1/2)" "$TMP_DIR/bootstrap-output.log"; then
  cat "$TMP_DIR/bootstrap-output.log"
  echo "FAIL: wrapper did not retry after XCTest bootstrap exit"
  exit 1
fi

bootstrap_count="$(grep -Fc "Early unexpected exit, operation never finished bootstrapping" "$TMP_DIR/bootstrap-output.log")"
if [ "$bootstrap_count" -ne 2 ]; then
  cat "$TMP_DIR/bootstrap-output.log"
  echo "FAIL: expected two XCTest bootstrap failures, got $bootstrap_count"
  exit 1
fi

echo "PASS: app-host xcodebuild wrapper retries XCTest bootstrap exits"
