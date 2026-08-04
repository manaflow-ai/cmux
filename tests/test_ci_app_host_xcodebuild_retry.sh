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
printf 'invoked\n' >> "$CMUX_CAPTURE_XCODEBUILD_INVOCATIONS"
case "$CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH" in
  *-attempt-1.log)
    printf '%s\n' \
      "SocketControlServer: Listening on /tmp/cmux-test.sock" \
      "Test Suite 'ExampleTests' failed" \
      "Executed 1 test, with 1 failure (0 unexpected)" \
      "Failed to establish communication with the test runner"
    exit 65
    ;;
  *)
    printf '%s\n' \
      "SocketControlServer: Listening on /tmp/cmux-test.sock" \
      "Test Suite 'Selected tests' passed" \
      "Executed 1 test, with 0 failures (0 unexpected)"
    ;;
esac
SH
chmod +x "$TMP_DIR/xcodebuild"

regression_failures=0
set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_CAPTURE_XCODEBUILD_INVOCATIONS="$TMP_DIR/assertion-retry-invocations.log" \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/assertion-retry-output.log" 2>&1
assertion_retry_status=$?
set -e

if [ "$assertion_retry_status" -eq 0 ]; then
  cat "$TMP_DIR/assertion-retry-output.log"
  echo "FAIL: a clean retry masked an XCTest assertion failure from the first attempt"
  regression_failures=$((regression_failures + 1))
fi

if ! grep -Fq "Detected 1 XCTest or Swift Testing failure markers." "$TMP_DIR/assertion-retry-output.log"; then
  cat "$TMP_DIR/assertion-retry-output.log"
  echo "FAIL: assertion diagnostics must report a sanitized marker count"
  regression_failures=$((regression_failures + 1))
fi

assertion_retry_invocations="$(wc -l < "$TMP_DIR/assertion-retry-invocations.log" | tr -d ' ')"
if [ "$assertion_retry_invocations" -ne 1 ]; then
  cat "$TMP_DIR/assertion-retry-output.log"
  echo "FAIL: an app-host assertion failure must stop retries; got $assertion_retry_invocations invocations"
  regression_failures=$((regression_failures + 1))
fi

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' \
  "SocketControlServer: Listening on /tmp/cmux-test.sock" \
  "Test Suite 'ExampleTests' failed" \
  "Executed 1 test, with 1 failure (0 unexpected)" \
  "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches." \
  "Test Suite 'Selected tests' passed" \
  "Executed 1 test, with 0 failures (0 unexpected)"
SH
chmod +x "$TMP_DIR/xcodebuild"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/xctest-summary-loss-output.log" 2>&1
xctest_summary_loss_status=$?
set -e

if [ "$xctest_summary_loss_status" -eq 0 ]; then
  cat "$TMP_DIR/xctest-summary-loss-output.log"
  echo "FAIL: a final clean XCTest summary masked an earlier assertion failure"
  regression_failures=$((regression_failures + 1))
fi

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' \
  "SocketControlServer: Listening on /tmp/cmux-test.sock" \
  "Test Suite 'Selected tests' passed" \
  "Executed 1 test, with 0 failures (0 unexpected)" \
  "✘ Test example() recorded an issue at ExampleTests.swift:12:3: Expectation failed" \
  "✘ Test example() failed after 0.001 seconds with 1 issue."
SH
chmod +x "$TMP_DIR/xcodebuild"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/swift-testing-summary-loss-output.log" 2>&1
swift_testing_summary_loss_status=$?
set -e

if [ "$swift_testing_summary_loss_status" -eq 0 ]; then
  cat "$TMP_DIR/swift-testing-summary-loss-output.log"
  echo "FAIL: a final clean XCTest summary masked a Swift Testing assertion failure"
  regression_failures=$((regression_failures + 1))
fi

set +e
ROOT_DIR="$ROOT_DIR" python3 <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml


root = Path(os.environ["ROOT_DIR"])
workflow = yaml.safe_load((root / ".github/workflows/ci.yml").read_text())
steps = workflow["jobs"]["app-host-unit-tests"]["steps"]
run_unit_tests = next(step["run"] for step in steps if step.get("name") == "Run unit tests")
run_unit_tests = run_unit_tests.replace("${{ matrix.shard }}", "1")

with tempfile.TemporaryDirectory() as raw_tmp:
    fixture = Path(raw_tmp)
    scripts = fixture / "scripts/ci"
    scripts.mkdir(parents=True)
    runner_temp = fixture / "runner-temp"
    runner_temp.mkdir()

    (scripts / "cmux_unit_test_shard.py").write_text(
        """\
from pathlib import Path
import sys

output = Path(sys.argv[sys.argv.index("--output") + 1])
output.write_text("-only-testing:cmuxTests/ExampleTests\\n")
"""
    )
    (scripts / "run-in-console-session.sh").write_text(
        """\
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
"""
    )
    (scripts / "run-app-host-xcodebuild.sh").write_text(
        """\
#!/usr/bin/env bash
printf '%s\\n' \\
  "Test Suite 'ExampleTests' failed" \\
  "Executed 2 tests, with 1 failure (0 unexpected)" \\
  "Test Suite 'Selected tests' passed" \\
  "Executed 2 tests, with 0 failures (0 unexpected)"
exit 65
"""
    )
    (scripts / "run-in-console-session.sh").chmod(0o755)
    (scripts / "run-app-host-xcodebuild.sh").chmod(0o755)

    env = os.environ.copy()
    env.update(
        RUNNER_TEMP=str(runner_temp),
        CMUX_DERIVED_DATA_PATH=str(fixture / "derived-data"),
        CMUX_UNIT_TEST_TIMEOUT_SECONDS="30",
    )
    result = subprocess.run(
        ["bash", "-c", run_unit_tests],
        cwd=fixture,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )

if result.returncode == 0:
    print(result.stdout, end="")
    print(
        "FAIL: the app-host unit-test workflow treated an ordinary assertion "
        "failure with '(0 unexpected)' as a pass"
    )
    sys.exit(1)
PY
workflow_failure_status=$?
set -e

if [ "$workflow_failure_status" -ne 0 ]; then
  regression_failures=$((regression_failures + 1))
fi

if [ "$regression_failures" -ne 0 ]; then
  echo "FAIL: detected $regression_failures app-host test failure-accounting regressions"
  exit 1
fi

echo "PASS: app-host xcodebuild retries infrastructure failures without masking test failures"
