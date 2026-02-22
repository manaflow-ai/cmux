#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

allowed_a="Sources/Find/SurfaceSearchOverlay.swift"
allowed_b="Sources/GhosttyTerminalView.swift"
pattern='SurfaceSearchOverlay[[:space:]]*\('

if command -v rg >/dev/null 2>&1; then
  matches="$(
    rg -n --no-heading --glob '*.swift' "$pattern" Sources cmuxTests \
      | grep -v "^${allowed_a}:" \
      | grep -v "^${allowed_b}:" \
      || true
  )"
else
  matches="$(
    grep -RIn --include='*.swift' -E "$pattern" Sources cmuxTests \
      | grep -v "^${allowed_a}:" \
      | grep -v "^${allowed_b}:" \
      || true
  )"
fi

if [[ -n "$matches" ]]; then
  echo "Terminal overlay layering contract violation:"
  echo "SurfaceSearchOverlay may only be instantiated in:"
  echo "  - ${allowed_a}"
  echo "  - ${allowed_b}"
  echo
  echo "$matches"
  exit 1
fi

echo "OK: terminal overlay layering contract satisfied."
