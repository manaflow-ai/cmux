#!/usr/bin/env bash
# Open a URL, wait for SPA hydration, snapshot, and validate the result.
# Usage: spa-hydration-wait.sh <url> [workspace-id]
set -euo pipefail

URL="${1:?usage: spa-hydration-wait.sh <url> [workspace-id]}"
WORKSPACE="${2:-}"

# Open. Inside cmux, $CMUX_WORKSPACE_ID is used automatically; outside, pass a workspace id.
if [ -n "$WORKSPACE" ]; then
  SURFACE=$(cmux browser open "$URL" --workspace "$WORKSPACE" | grep -oE 'surface:[0-9]+')
else
  SURFACE=$(cmux browser open "$URL" | grep -oE 'surface:[0-9]+')
fi
echo "surface: $SURFACE"

# 1. Network-level load gate.
cmux browser "$SURFACE" wait --load-state complete --timeout-ms 15000

# 2. Detect SPA (informational; the content-density wait runs either way).
IS_SPA=$(cmux browser "$SURFACE" eval '!!(window.__NEXT_DATA__||window.__NUXT__||window.__remixContext||window.__SVELTEKIT_DATA__||window.___gatsby||window.__INITIAL_STATE__||window.ng||document.querySelector("[data-reactroot],[data-v-app],[data-server-rendered],[ng-version],[data-svelte-h],[q\\:container]"))' 2>/dev/null | tr -d '"' | tr -d ' \n')
echo "spa-detected: ${IS_SPA:-unknown}"

# 3. Content-density hydration wait. Never swallow the timeout.
cmux browser "$SURFACE" wait \
  --function 'document.readyState==="complete" && !document.querySelector("[aria-busy=true],[data-loading=true]") && document.body.innerText.length>30' \
  --timeout-ms 10000 \
  || { echo "hydration wait timed out — supply an explicit selector and retry" >&2; exit 1; }

# 4. Snapshot.
cmux browser "$SURFACE" snapshot --interactive

# 5. Validate: < 3 interactive/heading nodes means a pre-hydration shell.
NODE_COUNT=$(cmux browser "$SURFACE" eval 'document.querySelectorAll("a[href],h1,h2,h3,button,nav,article").length' | tr -d ' \n')
if [ "${NODE_COUNT:-0}" -lt 3 ]; then
  echo "snapshot validation: only ${NODE_COUNT:-0} elements — retrying with longer timeout" >&2
  cmux browser "$SURFACE" wait \
    --function 'document.readyState==="complete" && !document.querySelector("[aria-busy=true],[data-loading=true]") && document.body.innerText.length>30' \
    --timeout-ms 15000 \
    || { echo "hydration retry timed out — supply an explicit selector and retry" >&2; exit 1; }
  cmux browser "$SURFACE" snapshot --interactive
  # Re-validate after the retry — a still-shell page must NOT exit 0 as "hydrated".
  NODE_COUNT=$(cmux browser "$SURFACE" eval 'document.querySelectorAll("a[href],h1,h2,h3,button,nav,article").length' | tr -d ' \n')
  if [ "${NODE_COUNT:-0}" -lt 3 ]; then
    echo "snapshot still a pre-hydration shell after retry (${NODE_COUNT:-0} elements) — supply an explicit selector and retry" >&2
    exit 1
  fi
fi

echo "hydrated. surface=$SURFACE node_count=${NODE_COUNT:-0}"
