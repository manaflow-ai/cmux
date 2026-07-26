#!/usr/bin/env bash
set -euo pipefail

WEB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WEB_ROOT"

if (( $# > 0 )); then
  exec bun test --isolate "$@"
fi

test_files=()
while IFS= read -r test_file; do
  test_files+=("$test_file")
done < <(
  find . \
    \( -type d \( -name node_modules -o -name '.*' \) ! -path . -prune \) -o \
    -type f -print |
    awk '/(\.test|_test|\.spec|_spec)\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/' |
    LC_ALL=C sort
)

if (( ${#test_files[@]} == 0 )); then
  echo "No web test files found" >&2
  exit 1
fi

exec bun test --isolate "${test_files[@]}"
