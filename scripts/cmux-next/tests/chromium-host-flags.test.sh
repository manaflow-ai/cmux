#!/usr/bin/env bash
# The Chromium host links build-cef-shim.sh's libcef_dll_wrapper.a, so it must
# compile with the wrapper's flags. build-chromium-host.sh keeps its own copy
# of build-cef-shim.sh's `common` array (a file the shim build key and the
# runtime pack key hash must not change for the Debug-only host), and this
# test fails when the two copies differ. No compiler, no CEF.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# either script's flags.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

common_of() { # <script> -> the lines of its `common=(` ... `)` block
  awk '/^common=\($/ { inside = 1; next } inside && /^\)$/ { exit } inside { print }' "$1"
}
shim="$(common_of "$here/../build-cef-shim.sh")"
host="$(common_of "$here/../build-chromium-host.sh")"
[[ -n "$shim" ]] || fail "build-cef-shim.sh has no common=( ... ) block"
[[ -n "$host" ]] || fail "build-chromium-host.sh has no common=( ... ) block"
if [[ "$shim" != "$host" ]]; then
  diff <(printf '%s\n' "$shim") <(printf '%s\n' "$host") >&2 || true
  fail "build-chromium-host.sh compiles with other flags than the wrapper it links (build-cef-shim.sh)"
fi
echo "chromium-host-flags tests: ok"
