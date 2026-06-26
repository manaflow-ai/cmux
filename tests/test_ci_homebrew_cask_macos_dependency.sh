#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/5877.
# Homebrew now warns on comparison-string macOS requirements in casks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FILES=(
  "$ROOT_DIR/.github/workflows/update-homebrew.yml"
  "$ROOT_DIR/scripts/build-sign-upload.sh"
)

fail=0
for file in "${FILES[@]}"; do
  if ! grep -Fq 'depends_on macos: :sonoma' "$file"; then
    echo "FAIL: $file must generate a cask with depends_on macos: :sonoma" >&2
    fail=1
  fi

  if grep -Eq 'depends_on macos:[[:space:]]*"[^"]*:[[:alpha:]_][[:alpha:]_0-9]*"' "$file"; then
    echo "FAIL: $file must not use the deprecated comparison-string macOS cask requirement" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: Homebrew cask macOS dependency uses the symbol requirement form"
