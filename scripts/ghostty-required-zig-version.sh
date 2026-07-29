#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${GHOSTTY_ZIG_MANIFEST:-$SCRIPT_DIR/../ghostty/build.zig.zon}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "error: Ghostty Zig manifest not found: $MANIFEST" >&2
  exit 1
fi

version="$(
  awk -F '"' \
    '/^[[:space:]]*\.minimum_zig_version[[:space:]]*=/ { print $2; exit }' \
    "$MANIFEST"
)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z]+)*$ ]]; then
  echo "error: invalid Ghostty minimum_zig_version in $MANIFEST" >&2
  exit 1
fi

printf '%s\n' "$version"
