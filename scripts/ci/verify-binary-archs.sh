#!/usr/bin/env bash
# Fails unless every binary contains exactly the expected architectures.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 \"<archs>\" <binary>..." >&2
  exit 2
fi

# shellcheck disable=SC2086
expected="$(printf '%s\n' $1 | sort | xargs)"
shift

for binary in "$@"; do
  actual="$(lipo -archs "$binary" | tr ' ' '\n' | sort | xargs)"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: $binary slices are '$actual', expected exactly '$expected'" >&2
    exit 1
  fi
  echo "$binary: $actual"
done
