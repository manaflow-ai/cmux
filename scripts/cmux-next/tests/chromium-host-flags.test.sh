#!/usr/bin/env bash
# The Chromium host links build-cef-shim.sh's libcef_dll_wrapper.a, so it must
# compile with the wrapper's flags, and it compiles the shim's sources, so they
# also get the shim's hardening. build-chromium-host.sh keeps its own copies of
# build-cef-shim.sh's `common` and `hardening` arrays (a file the shim build key
# and the runtime pack key hash must not change for the Debug-only host), and
# this test fails when a copy differs. No compiler, no CEF.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# either script's flags.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

block_of() { # <name> <script> -> the lines of its `<name>=(` ... `)` block
  awk -v start="$1=(" '$0 == start { inside = 1; next } inside && /^\)$/ { exit } inside { print }' "$2"
}
for name in common hardening; do
  shim="$(block_of "$name" "$here/../build-cef-shim.sh")"
  host="$(block_of "$name" "$here/../build-chromium-host.sh")"
  [[ -n "$shim" ]] || fail "build-cef-shim.sh has no $name=( ... ) block"
  [[ -n "$host" ]] || fail "build-chromium-host.sh has no $name=( ... ) block"
  if [[ "$shim" != "$host" ]]; then
    diff <(printf '%s\n' "$shim") <(printf '%s\n' "$host") >&2 || true
    fail "build-chromium-host.sh's $name differs from build-cef-shim.sh's (the wrapper it links, the shim sources it compiles)"
  fi
done
echo "chromium-host-flags tests: ok"
