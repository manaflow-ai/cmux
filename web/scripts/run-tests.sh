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
  find tests -maxdepth 1 -type f \
    \( -name '*.test.ts' -o -name '*.test.tsx' \) -print |
    sort
)

if (( ${#test_files[@]} == 0 )); then
  echo "No top-level web test files found" >&2
  exit 1
fi

exec bun test --isolate "${test_files[@]}"
