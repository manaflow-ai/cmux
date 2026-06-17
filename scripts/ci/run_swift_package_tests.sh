#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <PackageName> [<PackageName> ...]" >&2
  exit 2
fi

swift_test_timeout_seconds="${CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS:-900}"

for pkg in "$@"; do
  pkgdir=""
  for candidate in Packages/*/"$pkg"; do
    if [ -f "$candidate/Package.swift" ]; then
      pkgdir="$candidate"
      break
    fi
  done
  if [ -z "$pkgdir" ]; then
    echo "::error::package '$pkg' not found under Packages/*/ (renamed or moved?)"
    exit 1
  fi

  echo "::group::swift test $pkgdir"
  case "$pkg" in
  CmuxTerminal|CmuxTerminalCore|CmuxTerminalEngine|CmuxTerminalServices)
    status=0
    output_file="$(mktemp)"
    set +e
    python3 scripts/ci/run_with_timeout.py \
      --timeout "$swift_test_timeout_seconds" \
      -- swift test --package-path "$pkgdir" 2>&1 | tee "$output_file"
    status=${PIPESTATUS[0]}
    set -e
    output="$(cat "$output_file")"
    rm -f "$output_file"
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
    python3 scripts/ci/run_with_timeout.py \
      --timeout "$swift_test_timeout_seconds" \
      -- swift test --package-path "$pkgdir"
    ;;
  esac
  echo "::endgroup::"
done
