#!/usr/bin/env bash
set -euo pipefail
export CMUX_RESTORE_STARTED_NS="$(python3 -c 'import time; print(time.monotonic_ns())')"
report_restore_measurement() {
  local status="$?"
  set +e
  CMUX_RESTORE_STATUS="$status" python3 - <<'PY'
import json
import os
from pathlib import Path
import time

archive = Path(os.environ["RUNNER_TEMP"]) / "app-host-products/app-host-products.tar.gz"
layer_hit = os.environ.get("CMUX_LAYER_RESTORED") == "true"
elapsed = max(0.0, (time.monotonic_ns() - int(os.environ["CMUX_RESTORE_STARTED_NS"])) / 1_000_000_000)
# Compile admission restoring the archive it just packaged, for the changed
# suites it runs itself: no transport was involved.
producer_hit = os.environ.get("CMUX_PRODUCT_FROM_PRODUCER") == "true"
local_hit = os.environ.get("CMUX_NODE_PRODUCT_CACHE_HIT") == "true"
peer_hit = os.environ.get("CMUX_PEER_PRODUCT_HIT") == "true"
# "lan": another PR mini through glaeda's LAN helper; "peer": a trusted HTTPS peer.
peer_source = os.environ.get("CMUX_PEER_PRODUCT_SOURCE") or ("peer" if peer_hit else "")
r2_hit = os.environ.get("CMUX_R2_PRODUCT_HIT") == "true"
parallel_hit = os.environ.get("CMUX_PARALLEL_PRODUCT_HIT") == "true"
record = {
    "outcome": "success" if os.environ.get("CMUX_RESTORE_STATUS") == "0" else "failure",
    "r2_result": os.environ.get("CMUX_ARTIFACT_R2_RESULT") or "disabled",
    "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
    "repository": os.environ["GITHUB_REPOSITORY"],
    # test-e2e.yml's build job on an owned Mac restores its own archive
    # before it uploads it, so there is no artifact yet.
    "artifact_id": int(os.environ["ARTIFACT_ID"]) if os.environ.get("ARTIFACT_ID") else None,
    "provider_digest": os.environ.get("ARTIFACT_PROVIDER_DIGEST") or None,
    "archive_sha256": os.environ["EXPECTED_SHA256"],
    "product_contract": os.environ["CMUX_PRODUCT_CONTRACT"],
    "source_revision": os.environ["CMUX_PRODUCT_SOURCE_REVISION"],
    "producer_run_id": int(os.environ["CMUX_PRODUCT_PRODUCER_RUN_ID"]),
    "producer_run_attempt": int(os.environ["CMUX_PRODUCT_PRODUCER_RUN_ATTEMPT"]),
    "archive_bytes": archive.stat().st_size if archive.is_file() else 0,
    "layer_hit": layer_hit,
    "elapsed_seconds": round(elapsed, 6),
    "lookup_source": (
        "producer" if producer_hit else
        "local" if local_hit else
        ("lan" if peer_source == "lan" else "peer") if peer_hit else
        "layers-github" if layer_hit else
        "r2" if r2_hit else
        "github-parallel" if parallel_hit else
        "github"
    ),
    "local_hit": local_hit,
    "lookup_seconds": float(os.environ.get("CMUX_NODE_PRODUCT_CACHE_LOOKUP_SECONDS") or 0),
    "peer_hit": peer_hit,
    "peer_source": peer_source,
    "peer_lookup_seconds": float(os.environ.get("CMUX_PEER_PRODUCT_LOOKUP_SECONDS") or 0),
    "peer_transfer_seconds": float(os.environ.get("CMUX_PEER_PRODUCT_TRANSFER_SECONDS") or 0),
    "peer_bytes_transferred": int(os.environ.get("CMUX_PEER_PRODUCT_BYTES") or 0),
    "parallel_hit": parallel_hit,
    "parallel_transfer_seconds": float(os.environ.get("CMUX_PARALLEL_PRODUCT_TRANSFER_SECONDS") or 0),
    "run_id": os.environ.get("GITHUB_RUN_ID"),
    "job": os.environ.get("GITHUB_JOB"),
    "shard": os.environ.get("CMUX_APP_HOST_SHARD"),
    "runner_name": os.environ.get("RUNNER_NAME"),
    "canonical_root_lock_skipped": os.environ.get("CMUX_CI_ROOT_LOCK_SKIPPED") == "true",
}
record["route"] = record["lookup_source"]
print("CMUX_TEST_PRODUCT_RESTORE " + json.dumps(record, sort_keys=True))
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as handle:
        handle.write("### Compiled test product restore\n\n```json\n")
        handle.write(json.dumps(record, indent=2, sort_keys=True))
        handle.write("\n```\n")
PY
  return "$status"
}
trap report_restore_measurement EXIT
archive="$RUNNER_TEMP/app-host-products/app-host-products.tar.gz"
if [ "${CMUX_LAYER_RESTORED:-}" != "true" ]; then
  echo "$EXPECTED_SHA256  $archive" | shasum -a 256 -c -
  tar -xzf "$archive" -C "$CMUX_DERIVED_DATA_PATH"
fi
products="$CMUX_DERIVED_DATA_PATH/Build/Products/Debug"
# The product's Mach-O files look for package frameworks first at the
# DerivedData they were compiled in. On an owned Mac that path can hold the
# canonical root's kept build of another commit, so point them at this
# product's own frameworks before anything below copies them.
python3 scripts/ci/relocate_package_framework_rpaths.py "$products"
stable="$RUNNER_TEMP/cmux-app-host-package-frameworks"
stable_system="/private/tmp/cmux-app-host-package-frameworks"
mkdir -p "$stable"
framework_source="$(find "$products" -type d -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit 2>/dev/null || true)"
test -n "$framework_source"
rsync -aL --no-times "$(dirname "$framework_source")/" "$stable/"
mkdir -p "$stable_system"
rsync -aL --no-times "$(dirname "$framework_source")/" "$stable_system/"
if [ -L "$products/PackageFrameworks" ]; then
  rm "$products/PackageFrameworks"
fi
mkdir -p "$products/PackageFrameworks"
framework_source="$(find "$products" -type d -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit 2>/dev/null || true)"
test -n "$framework_source"
rsync -aL --no-times "$(dirname "$framework_source")/" "$products/PackageFrameworks/"
test -f "$products/PackageFrameworks/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct.framework/Versions/A/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct"
python3 scripts/ci/app_host_test_products.py restore "$CMUX_DERIVED_DATA_PATH"
# Source-backed test fixtures resolve #fileID through this stable runtime
# location, so consumers can alias their checkout without the producer root.
export CMUX_CI_RUNTIME_SOURCE_ROOT=/private/tmp/cmux-test-source
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "CMUX_CI_RUNTIME_SOURCE_ROOT=$CMUX_CI_RUNTIME_SOURCE_ROOT" >> "$GITHUB_ENV"
fi
scripts/ci/canonical-build-root.sh --runtime-source "$PWD"
