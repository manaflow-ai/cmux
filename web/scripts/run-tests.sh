#!/usr/bin/env bash
set -euo pipefail

WEB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WEB_ROOT"

default_test_file_exists() {
  while IFS= read -r -d '' file; do
    case "$file" in
      *.js | *.jsx | *.ts | *.tsx | *.mjs | *.cjs | *.mts | *.cts) ;;
      *) continue ;;
    esac
    case "${file##*/}" in
      *".test"* | *"_test_"* | *".spec"* | *"_spec_"*) return 0 ;;
    esac
  done < <(
    find . \
      \( -path "./node_modules" -o -path "./.next" \) -prune \
      -o -type f -print0
  )
  return 1
}

if (( $# == 0 )) && ! default_test_file_exists; then
  echo "cmux web test runner found no test files" >&2
  exit 1
fi

exec bun test --isolate "$@"
