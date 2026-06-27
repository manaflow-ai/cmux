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
expected_symbol=""
for file in "${FILES[@]}"; do
  if grep -Eq 'depends_on macos:[[:space:]]*"[^"]*:[[:alpha:]_][[:alpha:]_0-9]*"' "$file"; then
    echo "FAIL: $file must not use the deprecated comparison-string macOS cask requirement" >&2
    fail=1
  fi

  symbols="$(
    awk '
      /^[[:space:]]*depends_on macos:[[:space:]]*:[[:alpha:]_][[:alpha:]_0-9]*[[:space:]]*$/ {
        sub(/.*depends_on macos:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        print
      }
    ' "$file" | sort -u
  )"
  symbol_count="$(printf '%s\n' "$symbols" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$symbol_count" -ne 1 ]; then
    echo "FAIL: $file must generate exactly one symbol-form macOS cask requirement" >&2
    fail=1
    continue
  fi

  if [ -z "$expected_symbol" ]; then
    expected_symbol="$symbols"
  elif [ "$symbols" != "$expected_symbol" ]; then
    echo "FAIL: cask generators disagree on macOS requirement ($expected_symbol vs $symbols)" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: Homebrew cask macOS dependency uses the symbol requirement form ($expected_symbol)"
