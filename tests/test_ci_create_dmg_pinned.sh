#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/387.
# Ensures release workflows pin create-dmg to an explicit version.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

WORKFLOWS=(
  "$ROOT_DIR/.github/workflows/release.yml"
  "$ROOT_DIR/.github/workflows/nightly.yml"
)

for workflow in "${WORKFLOWS[@]}"; do
  if ! grep -Eq 'npm install --global .*create-dmg@' "$workflow"; then
    echo "FAIL: $workflow must install create-dmg with an explicit version"
    exit 1
  fi

  if grep -Eq 'npm install --global[[:space:]]+create-dmg([[:space:]]|$)' "$workflow"; then
    echo "FAIL: $workflow still has unpinned create-dmg install"
    exit 1
  fi
done

echo "PASS: create-dmg install is pinned in release workflows"
