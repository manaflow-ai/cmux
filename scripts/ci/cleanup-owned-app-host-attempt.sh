#!/usr/bin/env bash
set -euo pipefail

ci_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ci_script_dir/app-host-isolation.sh"
# shellcheck source=scripts/ci/app-host-processes.sh
source "$ci_script_dir/app-host-processes.sh"

if [ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-0}" != "1" ]; then
  echo "FAIL: refusing timeout cleanup without app-host isolation" >&2
  exit 1
fi
if [ "${CMUX_APP_HOST_TEST_LOCK_ACTIVE:-0}" != "1" ]; then
  echo "FAIL: timeout cleanup requires the canonical machine lock" >&2
  exit 1
fi
if [ -z "${CMUX_DERIVED_DATA_PATH:-}" ]; then
  echo "FAIL: timeout cleanup requires the shard DerivedData path" >&2
  exit 1
fi

cmux_validate_published_app_host_identity
cmux_validate_app_host_derived_data "$CMUX_DERIVED_DATA_PATH"

echo "Cleaning receipt-verified app-host processes before PTY termination" >&2
cmux_recover_owned_app_host_attempt \
  "$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR" \
  "$CMUX_RESOLVED_APP_HOST_KEY" \
  "$CMUX_VALIDATED_APP_HOST_DERIVED_DATA" \
  "$CMUX_RESOLVED_RUNNER_WORK_ROOT" \
  "$CMUX_RESOLVED_SYSTEM_TEMP_ROOT"
