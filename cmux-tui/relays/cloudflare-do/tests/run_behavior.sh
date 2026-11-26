#!/usr/bin/env bash
# Runs tests/relay_do_behavior.mjs against the built Worker (`npm run build` first) under `wrangler dev`: the
# real workerd runtime, which `cargo test` does not have. It is what catches a Worker that compiles and passes its
# unit tests but fails at runtime, as the 2026-11-25 staging relay did: `headers_mut` on the request workerd hands
# the Worker is an error, so every slot upgrade answered 500 (cloudflare-relay.yml runs this before any deploy).
#
# Usage: tests/run_behavior.sh [PORT]   (from cmux-tui/relays/cloudflare-do)
set -euo pipefail
port="${1:-8787}"
key="relay-behavior-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/relay-behavior-wrangler.log"
npx --no-install wrangler dev --ip 127.0.0.1 --port "$port" --var "CMUX_RELAY_TICKET_KEY:$key" \
  --show-interactive-dev-session=false >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 120); do
  curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && break
  kill -0 "$pid" 2>/dev/null || { echo "wrangler dev exited:"; tail -40 "$log"; exit 1; }
  sleep 1
done
rc=0
timeout 300 node tests/relay_do_behavior.mjs "http://127.0.0.1:$port" "$key" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "--- wrangler dev errors"
  grep -aiE "error|500 Internal" "$log" | tail -20 || true
fi
exit "$rc"
