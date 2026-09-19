#!/usr/bin/env bash
# Regression test: a checkout that was not created through cmuxterm-hq has no
# scripts/dev-backend.sh, so a tagged reload needs an explicit way to build
# against the local dev origin instead of exiting before the build starts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/dev-backend-origin.sh
source "$ROOT_DIR/scripts/lib/dev-backend-origin.sh"

CHECKOUT="$(mktemp -d)"
trap 'rm -rf "$CHECKOUT"' EXIT
mkdir -p "$CHECKOUT/scripts"
LOCAL_ORIGIN="http://localhost:4123"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Default stays strict: no helper and no URL is an error, and the message
# names the opt-in so a contributor is not left at a dead end.
unset CMUX_DEV_BACKEND_URL CMUX_DEV_BACKEND_MODE
if out="$(cmux_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN" 2>&1)"; then
  fail "default mode resolved '$out' without the shared backend helper"
fi
[[ "$out" == *"CMUX_DEV_BACKEND_MODE=local"* ]] \
  || fail "the error does not tell a non-hq checkout how to proceed: $out"
echo "PASS: default mode still requires the shared backend and names the opt-in"

# Opt-in: local mode returns the local dev origin and needs no helper.
out="$(CMUX_DEV_BACKEND_MODE=local cmux_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN")" \
  || fail "local mode failed without the shared backend helper"
[[ "$out" == "$LOCAL_ORIGIN" ]] || fail "local mode resolved '$out', expected '$LOCAL_ORIGIN'"
echo "PASS: CMUX_DEV_BACKEND_MODE=local resolves the local dev origin"

# Local mode must not quietly accept a shared URL, and an unknown mode is an error.
if CMUX_DEV_BACKEND_MODE=local CMUX_DEV_BACKEND_URL="https://cmux-dev-backend-1.tail137216.ts.net:3800/" \
    cmux_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN" >/dev/null 2>&1; then
  fail "local mode accepted CMUX_DEV_BACKEND_URL"
fi
if CMUX_DEV_BACKEND_MODE=bogus cmux_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN" >/dev/null 2>&1; then
  fail "an unknown CMUX_DEV_BACKEND_MODE was accepted"
fi
echo "PASS: local mode rejects a shared URL, and unknown modes are rejected"

# The shared path is unchanged: a valid tailnet URL still resolves.
out="$(CMUX_DEV_BACKEND_URL="https://cmux-dev-backend-1.tail137216.ts.net:3800" \
  cmux_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN")" || fail "shared URL no longer resolves"
[[ "$out" == "https://cmux-dev-backend-1.tail137216.ts.net:3800/" ]] || fail "shared URL resolved to '$out'"
echo "PASS: the shared backend path is unchanged"
