#!/usr/bin/env bash
# List every test the built cmuxTests bundle holds, and publish the inventory
# app_host_result_accounting.py grades each batch against. Shared by the
# app-host unit-test shards and compile admission's changed-suites run.
set -euo pipefail
enumeration_json="$RUNNER_TEMP/cmux-app-host-test-enumeration.json"
inventory_json="$RUNNER_TEMP/cmux-app-host-test-inventory.json"
enumeration_log="$RUNNER_TEMP/cmux-app-host-test-enumeration.log"
rm -f -- "$enumeration_json" "$inventory_json" "$enumeration_log"
runner_fault() {
  echo "::error title=App-host runner fault::${RUNNER_NAME:-this runner}: $1 Runner fault, not a test verdict; rerun the job." >&2
  exit 1
}
# Enumeration launches the app host, so it takes the same per-Mac lock as the
# test runs; a second host on one Mac drops the other's test-runner channel.
# When testmanagerd refuses xcodebuild, the host waits silently and xcodebuild
# needs about 700s to notice, so the idle timeout ends a stalled enumeration far
# sooner. A healthy one takes about 20s.
app_host_lock_file="$(cd /tmp && pwd -P)/cmux-app-host-test.lock"
enumeration_status=0
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS="${CMUX_APP_HOST_ENUMERATION_IDLE_TIMEOUT_SECONDS:-240}" \
  bash scripts/ci/run-and-capture.sh "$enumeration_log" \
  scripts/ci/run-in-console-session.sh \
  python3 scripts/ci/app_host_test_lock.py "$app_host_lock_file" 3600 \
  python3 scripts/ci/xcodebuild_noninteractive.py \
  xcodebuild test-without-building \
  -enumerate-tests \
  -xctestrun "$CMUX_APP_HOST_XCTESTRUN" \
  -destination "platform=macOS" \
  -test-enumeration-style hierarchical \
  -test-enumeration-format json \
  -test-enumeration-output-path "$enumeration_json" \
  || enumeration_status=$?
if [ "$enumeration_status" -eq 124 ]; then
  runner_fault "test enumeration stalled; the XCTest runner never connected to the app host."
fi
[ "$enumeration_status" -eq 0 ] || exit "$enumeration_status"
test -s "$enumeration_json"
# xcodebuild -enumerate-tests exits 0 when the runner hung; the JSON's errors say so.
if ! python3 scripts/ci/app_host_result_accounting.py inventory \
  "$enumeration_json" --output "$inventory_json"; then
  runner_fault "test enumeration failed (see the error above)."
fi
test -s "$inventory_json"
echo "CMUX_APP_HOST_TEST_INVENTORY=$inventory_json" >> "$GITHUB_ENV"
