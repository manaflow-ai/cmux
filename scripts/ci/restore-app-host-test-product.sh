#!/usr/bin/env bash
set -euo pipefail
restore_started_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
report_restore_measurement() {
  local status="$?"
  set +e
  CMUX_RESTORE_STATUS="$status" CMUX_RESTORE_STARTED_NS="$restore_started_ns" python3 - <<'PY'
import json
import os
from pathlib import Path
import time

started = int(os.environ.get("CMUX_RESTORE_STARTED_NS", "0") or 0)
elapsed = max(0, round((time.monotonic_ns() - started) / 1_000_000_000, 3)) if started else None
archive = Path(os.environ.get("RUNNER_TEMP", "")) / "app-host-products/app-host-products.tar.gz"
record = {
    "run_id": os.environ.get("GITHUB_RUN_ID"),
    "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
    "job": os.environ.get("GITHUB_JOB"),
    "shard": os.environ.get("CMUX_APP_HOST_SHARD"),
    "runner_name": os.environ.get("RUNNER_NAME"),
    "route": os.environ.get("CMUX_ARTIFACT_TRANSPORT_ROUTE") or "unknown",
    "r2_result": os.environ.get("CMUX_ARTIFACT_R2_RESULT") or "unknown",
    "outcome": "success" if os.environ.get("CMUX_RESTORE_STATUS") == "0" else "failure",
    "elapsed_seconds": elapsed,
    "archive_bytes": archive.stat().st_size if archive.is_file() else None,
}
print("CMUX_TEST_PRODUCT_RESTORE " + json.dumps(record, sort_keys=True))
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as handle:
        handle.write("### Compiled test product restore\n\n\`\`\`json\n")
        handle.write(json.dumps(record, indent=2, sort_keys=True))
        handle.write("\n\`\`\`\n")
PY
  set -e
  return "$status"
}
trap report_restore_measurement EXIT
archive="$RUNNER_TEMP/app-host-products/app-host-products.tar.gz"
echo "$EXPECTED_SHA256  $archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$CMUX_DERIVED_DATA_PATH"
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
