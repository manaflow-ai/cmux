#!/usr/bin/env bash
# List every test the built cmuxTests bundle holds, and publish the inventory
# app_host_result_accounting.py grades each batch against. Shared by the
# app-host unit-test shards and compile admission's changed-suites run.
set -euo pipefail
enumeration_json="$RUNNER_TEMP/cmux-app-host-test-enumeration.json"
inventory_json="$RUNNER_TEMP/cmux-app-host-test-inventory.json"
enumeration_log="$RUNNER_TEMP/cmux-app-host-test-enumeration.log"
rm -f -- "$enumeration_json" "$inventory_json" "$enumeration_log"
bash scripts/ci/run-and-capture.sh "$enumeration_log" \
  scripts/ci/run-in-console-session.sh \
  xcodebuild test-without-building \
  -enumerate-tests \
  -xctestrun "$CMUX_APP_HOST_XCTESTRUN" \
  -destination "platform=macOS" \
  -test-enumeration-style hierarchical \
  -test-enumeration-format json \
  -test-enumeration-output-path "$enumeration_json"
test -s "$enumeration_json"
python3 scripts/ci/app_host_result_accounting.py inventory \
  "$enumeration_json" --output "$inventory_json"
test -s "$inventory_json"
echo "CMUX_APP_HOST_TEST_INVENTORY=$inventory_json" >> "$GITHUB_ENV"
