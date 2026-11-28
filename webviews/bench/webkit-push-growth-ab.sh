#!/usr/bin/env bash
# Runs webkit-push-growth.bench.ts MODE=A and MODE=B side by side for ENGINE (default chromium); prints both RESULT lines.
set -euo pipefail
cd "$(dirname "$0")/.."
engine="${ENGINE:-chromium}"; minutes="${MINUTES:-8}"
out="${FAST_CHECKS_OUT:-/tmp}"
npx playwright install "$engine" >/dev/null 2>&1 || true
ENGINE=$engine MODE=A MINUTES=$minutes OUT="$out/$engine-A.json" bun bench/webkit-push-growth.bench.ts > "$out/$engine-A.log" 2>&1 &
a=$!
ENGINE=$engine MODE=B MINUTES=$minutes OUT="$out/$engine-B.json" bun bench/webkit-push-growth.bench.ts > "$out/$engine-B.log" 2>&1 &
b=$!
wait $a; ra=$?; wait $b; rb=$?
tail -n 3 "$out/$engine-A.log" "$out/$engine-B.log"
exit $(( ra | rb ))
