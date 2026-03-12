#!/usr/bin/env bash
# Regression test for the signed DMG packaging toolchain.
# Ensures release workflows provision the styled Homebrew create-dmg formula
# and do not silently switch to the generic npm CLI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

WORKFLOWS=(
  "$ROOT_DIR/.github/workflows/release.yml"
  "$ROOT_DIR/.github/workflows/nightly.yml"
)

for workflow in "${WORKFLOWS[@]}"; do
  if ! grep -Eq 'brew list create-dmg >/dev/null 2>&1 \|\| brew install create-dmg' "$workflow"; then
    echo "FAIL: $workflow must provision the Homebrew create-dmg formula"
    exit 1
  fi

  if grep -Eq 'npm install --global .*create-dmg' "$workflow"; then
    echo "FAIL: $workflow still installs the npm create-dmg CLI"
    exit 1
  fi
done

echo "PASS: signed workflows provision the styled create-dmg formula"
