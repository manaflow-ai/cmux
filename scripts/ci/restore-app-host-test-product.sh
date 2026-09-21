#!/usr/bin/env bash
set -euo pipefail

restore_started_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
record_restore_receipt() {
  local status="$?"
  local outcome="failure"
  local elapsed
  trap - EXIT
  if [ "$status" -eq 0 ]; then
    outcome="success"
  fi
  elapsed="$(python3 -c 'import sys,time; print(round((time.monotonic_ns()-int(sys.argv[1]))/1_000_000_000, 3))' "$restore_started_ns")" || elapsed="0"
  python3 scripts/ci/app_host_consumer_receipt.py restore --seconds "$elapsed" --outcome "$outcome" || true
  exit "$status"
}
trap record_restore_receipt EXIT
if [ "${CMUX_LAYER_RESTORED:-}" = "true" ]; then
  # Layer assembly already verified provider and inner archive integrity. Keep
  # the real producer warning evidence and the ordinary restore validations.
  python3 scripts/ci/app_host_layer_transport.py restore-warning-log "$CMUX_DERIVED_DATA_PATH"
  python3 scripts/swift_warning_budget.py --log "$CMUX_DERIVED_DATA_PATH/cmux-build.log"
else
  archive="$RUNNER_TEMP/app-host-products/app-host-products.aar"
  echo "$EXPECTED_SHA256  $archive" | shasum -a 256 -c -
  "$(dirname "$0")/app-host-products-archive.sh" unpack "$archive" "$CMUX_DERIVED_DATA_PATH"
fi
products="$CMUX_DERIVED_DATA_PATH/Build/Products/Debug"
stable="$RUNNER_TEMP/cmux-app-host-package-frameworks"
stable_system="/private/tmp/cmux-app-host-package-frameworks"
mkdir -p "$stable"
framework_source="$(find "$products" -type d -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit 2>/dev/null || true)"
test -n "$framework_source"
rsync -aL "$(dirname "$framework_source")/" "$stable/"
mkdir -p "$stable_system"
rsync -aL "$(dirname "$framework_source")/" "$stable_system/"
if [ -L "$products/PackageFrameworks" ]; then
  rm "$products/PackageFrameworks"
fi
mkdir -p "$products/PackageFrameworks"
framework_source="$(find "$products" -type d -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit 2>/dev/null || true)"
test -n "$framework_source"
rsync -aL "$(dirname "$framework_source")/" "$products/PackageFrameworks/"
test -f "$products/PackageFrameworks/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct.framework/Versions/A/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct"
python3 scripts/ci/app_host_test_products.py restore "$CMUX_DERIVED_DATA_PATH"

