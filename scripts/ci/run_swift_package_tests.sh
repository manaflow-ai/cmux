#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <PackageName> [<PackageName> ...]" >&2
  exit 2
fi

for pkg in "$@"; do
  echo "::group::swift test Packages/$pkg"
  case "$pkg" in
  CmuxTerminal|CmuxTerminalCore|CmuxTerminalEngine|CmuxTerminalServices)
    status=0
    output="$(swift test --package-path "Packages/$pkg" 2>&1)" || status=$?
    printf '%s\n' "$output"
    if [ "$status" -ne 0 ]; then
      if printf '%s\n' "$output" | grep -Eq 'Test run with [0-9]+ tests( in [0-9]+ suites)? passed' \
        && ! printf '%s\n' "$output" | grep -Eq 'with [1-9][0-9]* failures?' \
        && ! printf '%s\n' "$output" | grep -v 'unexpected binary' | grep -Eq '(^|[^a-zA-Z])error:'; then
        echo "Tolerated cosmetic GhosttyKit binaryTarget diagnostic; all tests passed."
      else
        exit "$status"
      fi
    fi
    ;;
  *)
    swift test --package-path "Packages/$pkg"
    ;;
  esac
  echo "::endgroup::"
done
