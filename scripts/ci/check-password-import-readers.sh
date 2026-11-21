#!/usr/bin/env bash
# Verify that a Release app does not contain the browser password readers.
# Inspect symbols and runtime strings separately: a recursive grep of a -g
# binary also sees source filenames in DWARF (for example,
# ChromiumLoginDataReader.swift) after the reader has been compiled out.
# Given the app executable, it also inspects the sibling
# ../Frameworks/CmuxNextApp.framework when there is one: cmux NEXT's code lives
# there behind a stub executable (CMUX-629); a static build keeps it in the
# executable.
set -euo pipefail

binary="${1:?usage: $0 /path/to/cmux}"
if [ ! -f "$binary" ]; then
  echo "FAIL: app executable is missing: $binary" >&2
  exit 1
fi

if ! command -v nm >/dev/null 2>&1; then
  echo "FAIL: nm is required to inspect Swift symbols" >&2
  exit 1
fi

images=("$binary")
framework="$(dirname "$binary")/../Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp"
if [ -f "$framework" ]; then
  images+=("$framework")
fi

for image in "${images[@]}"; do
  if symbol_hits="$(nm -U "$image" 2>/dev/null | grep -E 'ChromiumLoginDataReader|FirefoxPasswordCrypto' || true)"; then
    if [ -n "$symbol_hits" ]; then
      printf 'the notary test build still carries password-reader symbols in %s:\n%s\n' "$image" "$symbol_hits" >&2
      exit 1
    fi
  fi

  if string_hits="$(strings "$image" | grep -F 'nssPrivate' || true)"; then
    if [ -n "$string_hits" ]; then
      printf 'the notary test build still carries the Firefox password table in %s:\n%s\n' "$image" "$string_hits" >&2
      exit 1
    fi
  fi

  echo "password-import readers absent from $image"
done
