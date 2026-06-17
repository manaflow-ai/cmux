#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <package-dir> [swift-test-args...]" >&2
  exit 2
fi

pkgdir="$1"
shift
pkg="$(basename "$pkgdir")"

case "$pkg" in
CmuxTerminal|CmuxTerminalCore|CmuxTerminalEngine|CmuxTerminalServices)
  status=0
  output="$(swift test --package-path "$pkgdir" "$@" 2>&1)" || status=$?
  printf '%s\n' "$output"
  if [ "$status" -ne 0 ]; then
    if printf '%s\n' "$output" | grep -Eq 'Test run with [0-9]+ tests( in [0-9]+ suites?)? passed' \
      && ! printf '%s\n' "$output" | grep -Eq 'with [1-9][0-9]* failures?' \
      && ! printf '%s\n' "$output" | grep -v 'unexpected binary' | grep -Eq '(^|[^a-zA-Z])error:'; then
      echo "Tolerated cosmetic GhosttyKit binaryTarget diagnostic; all tests passed."
    else
      exit "$status"
    fi
  fi
  ;;
*)
  swift test --package-path "$pkgdir" "$@"
  ;;
esac
