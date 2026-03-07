#!/usr/bin/env bash
# Regression test for GhosttyKit artifact integrity verification in workflows.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

WORKFLOWS=(
  "$ROOT_DIR/.github/workflows/ci.yml"
  "$ROOT_DIR/.github/workflows/nightly.yml"
  "$ROOT_DIR/.github/workflows/release.yml"
)

for workflow in "${WORKFLOWS[@]}"; do
  if ! grep -Fq 'RELEASE_API_URL="https://api.github.com/repos/manaflow-ai/ghostty/releases/tags/$TAG"' "$workflow"; then
    echo "FAIL: $workflow missing release metadata lookup for GhosttyKit"
    exit 1
  fi

  if ! grep -Fq "asset.get('digest', '')" "$workflow"; then
    echo "FAIL: $workflow missing digest extraction from release asset metadata"
    exit 1
  fi

  if ! grep -Fq 'ACTUAL_SHA256=$(shasum -a 256 GhosttyKit.xcframework.tar.gz' "$workflow"; then
    echo "FAIL: $workflow missing GhosttyKit sha256 computation"
    exit 1
  fi

  if ! grep -Fq 'GhosttyKit.xcframework.tar.gz checksum mismatch' "$workflow"; then
    echo "FAIL: $workflow missing checksum mismatch failure guard"
    exit 1
  fi
done

echo "PASS: GhosttyKit checksum verification guard is present in build workflows"
