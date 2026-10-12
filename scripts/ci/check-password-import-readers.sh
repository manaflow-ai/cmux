#!/usr/bin/env bash
# Verify that a Release app does not contain the browser password readers.
# Inspect symbols and runtime strings separately: a recursive grep of a -g
# binary also sees source filenames in DWARF (for example,
# ChromiumLoginDataReader.swift) after the reader has been compiled out.
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

if symbol_hits="$(nm -U "$binary" 2>/dev/null | grep -E 'ChromiumLoginDataReader|FirefoxPasswordCrypto' || true)"; then
  if [ -n "$symbol_hits" ]; then
    printf 'the notary test build still carries password-reader symbols:\n%s\n' "$symbol_hits" >&2
    exit 1
  fi
fi

if string_hits="$(strings "$binary" | grep -F 'nssPrivate' || true)"; then
  if [ -n "$string_hits" ]; then
    printf 'the notary test build still carries the Firefox password table:\n%s\n' "$string_hits" >&2
    exit 1
  fi
fi

echo "password-import readers absent from $binary"
