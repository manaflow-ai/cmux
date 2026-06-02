#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -z "${DIRECT_DATABASE_URL:-${DATABASE_URL:-}}" ]]; then
  echo "DATABASE_URL or DIRECT_DATABASE_URL is required for DB behavior tests" >&2
  exit 2
fi

export CMUX_DB_TEST=1

test_files=()
while IFS= read -r test_file; do
  if grep -q "CMUX_DB_TEST" "$test_file"; then
    test_files+=("$test_file")
  fi
done < <(find tests -name "*.test.ts" -print | sort)

if [[ "${#test_files[@]}" -eq 0 ]]; then
  echo "No CMUX_DB_TEST-gated test files found" >&2
  exit 1
fi

printf 'Running %s DB behavior test file(s) with CMUX_DB_TEST=1\n' "${#test_files[@]}"
for test_file in "${test_files[@]}"; do
  printf '\n==> bun test %s\n' "$test_file"
  bun test "$test_file"
done
