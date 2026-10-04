#!/usr/bin/env bash
# Testbox only: starts the webviews dev server on one fixture with the real release sidecar,
# makes one warm-up load, then runs browser-stages.mjs. Prints JSON lines.
# Usage: run-browser.sh <fixture> <browsers> <runs> [query]
set -euo pipefail
[[ "${CMUX_TESTBOX_REMOTE:-}" == 1 ]] || { echo "testbox only" >&2; exit 64; }
fixture="$1"
browsers="$2"
runs="$3"
query="${4:-source=branch&base=HEAD~1}"
port=$((4300 + RANDOM % 500))
cd ~/perf/cmux/webviews
log="$(mktemp)"
CMUX_WEBVIEWS_DEV_PORT=$port CMUX_DIFF_SIDECAR=${PERF_SIDECAR:-$HOME/perf/target/release/cmux-diff-sidecar} \
  CMUX_DIFF_DEV_REPO=$HOME/perf/fixtures/$fixture CMUX_DIFF_DEV_BASE=HEAD~1 CMUX_DIFF_DEV_CMUX=/bin/false \
  setsid bun run dev --host 127.0.0.1 --port "$port" >"$log" 2>&1 &
server=$!
trap 'kill -- -$server 2>/dev/null || true; rm -f "$log"' EXIT
for _ in $(seq 1 120); do
  curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
  sleep 0.5
done
url="http://127.0.0.1:$port/${PERF_PAGE:-diff/}?$query"
[[ -n "${PERF_DUMP:-}" ]] && { node bench/perf/${PERF_DUMP_SCRIPT:-dump-line.mjs} "$url"; exit 0; }
PERF_TIMEOUT_MS=${PERF_TIMEOUT_MS:-180000} node bench/perf/browser-stages.mjs "$url" "$fixture" chromium 1 >/dev/null 2>&1 || true
PERF_TIMEOUT_MS=${PERF_TIMEOUT_MS:-180000} node bench/perf/browser-stages.mjs "$url" "$fixture" "$browsers" "$runs"
