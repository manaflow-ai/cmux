#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/387.
# Ensures release workflows pin create-dmg to an explicit version.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# nightly.yml runs its create-dmg install as scripts/ci/nightly-steps/install-create-dmg.sh; read it inline.
NIGHTLY_TEXT="$(mktemp)"
trap 'rm -f "$NIGHTLY_TEXT"' EXIT
python3 "$ROOT_DIR/tests/nightly_workflow_text.py" > "$NIGHTLY_TEXT"

WORKFLOWS=(
  "$ROOT_DIR/.github/workflows/release.yml"
  "$NIGHTLY_TEXT"
)

label() {
  if [ "$1" = "$NIGHTLY_TEXT" ]; then echo "$ROOT_DIR/.github/workflows/nightly.yml"; else echo "$1"; fi
}

for workflow in "${WORKFLOWS[@]}"; do
  if ! grep -Eq 'npm install --global .*create-dmg@' "$workflow"; then
    echo "FAIL: $(label "$workflow") must install create-dmg with an explicit version"
    exit 1
  fi

  if grep -Eq 'npm install --global[[:space:]]+create-dmg([[:space:]]|$)' "$workflow"; then
    echo "FAIL: $(label "$workflow") still has unpinned create-dmg install"
    exit 1
  fi
done

echo "PASS: create-dmg install is pinned in release workflows"
