#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
out="$1"; mkdir -p "$out"
F="src/agent-session/acpmux/conversation/ActivityLine.tsx src/agent-session/acpmux/conversation/LiveSpotShimmer.gallery.tsx test/live-spot-one-shimmer.test.tsx"
bun x vp fmt $F 2>&1 | tail -3
for f in $F; do mkdir -p "$out/$(dirname $f)"; cp "$f" "$out/$f"; done
rc=0
bun x vp lint $F 2>&1 | tail -15 || rc=1
bun test test/live-spot-one-shimmer.test.tsx test/transcript-live-line-state.test.tsx 2>&1 | tail -5 || rc=1
exit $rc
