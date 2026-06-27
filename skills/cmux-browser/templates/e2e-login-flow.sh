#!/usr/bin/env bash
# Login E2E with hydration waits on both the form page and the post-login destination.
# Usage: CMUX_E2E_PASSWORD=... e2e-login-flow.sh <login-url> <email> [workspace-id]
# The password is read from the CMUX_E2E_PASSWORD env var, NOT argv — a positional
# secret would leak into shell history and the process table (`ps`).
set -euo pipefail

LOGIN_URL="${1:?usage: CMUX_E2E_PASSWORD=... e2e-login-flow.sh <login-url> <email> [workspace-id]}"
EMAIL="${2:?email required}"
WORKSPACE="${3:-}"
PASSWORD="${CMUX_E2E_PASSWORD:?set CMUX_E2E_PASSWORD env var (do not pass the password as an argument)}"

if [ -n "$WORKSPACE" ]; then
  SURFACE=$(cmux browser open "$LOGIN_URL" --workspace "$WORKSPACE" | grep -oE 'surface:[0-9]+')
else
  SURFACE=$(cmux browser open "$LOGIN_URL" | grep -oE 'surface:[0-9]+')
fi
echo "surface: $SURFACE"

# Hydrate the login page before touching the form.
cmux browser "$SURFACE" wait --load-state complete --timeout-ms 15000
cmux browser "$SURFACE" wait \
  --function 'document.body.innerText.length>50 && document.querySelectorAll("a[href],button,input").length>2' \
  --timeout-ms 10000 \
  || { echo "login page hydration timed out" >&2; exit 1; }

# Fill and submit.
cmux browser "$SURFACE" wait --selector "#email" --timeout-ms 10000
cmux browser "$SURFACE" fill "#email" "$EMAIL"
cmux browser "$SURFACE" fill "#password" "$PASSWORD"
cmux browser "$SURFACE" click "button[type='submit']"

# The destination route hydrates client-side too — wait again before asserting.
cmux browser "$SURFACE" wait --url-contains "/dashboard" --timeout-ms 15000
cmux browser "$SURFACE" wait --load-state complete --timeout-ms 15000
cmux browser "$SURFACE" wait \
  --function 'document.body.innerText.length>100 && document.querySelectorAll("a[href],button").length>3' \
  --timeout-ms 10000 \
  || { echo "dashboard hydration timed out" >&2; exit 1; }

cmux browser "$SURFACE" snapshot --interactive

# Assertions. Customize the success selector for your app. This MUST gate the result:
# do not append `|| true` — that would let a failed login report success under `set -e`.
cmux browser "$SURFACE" get url
cmux browser "$SURFACE" errors list
if ! cmux browser "$SURFACE" is visible --selector "#success-message"; then
  echo "login flow FAILED — success indicator not visible" >&2
  exit 1
fi
echo "login flow complete. surface=$SURFACE"
