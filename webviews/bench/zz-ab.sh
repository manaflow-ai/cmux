#!/bin/bash
# base vs fix, interleaved A B B A on one host; prints load per run.
cd "$(dirname "$0")/.."
W=$PWD
echo "== HOST $(hostname) nproc=$(nproc)"; uptime
./node_modules/.bin/playwright install webkit >/dev/null 2>&1 || true
B=$W/../webviews-zzbase
mkdir -p "$B"
tar -C "$W" --exclude=./node_modules --exclude=./dist -cf - . | tar -C "$B" -xf -
ln -sfn "$W/node_modules" "$B/node_modules"
cp "$W/bench/zz-base-App.tsx" "$B/src/agent-session/acpmux/App.tsx"
cp "$W/bench/zz-base-paneSnapshot.ts" "$B/src/agent-session/acpmux/pane/paneSnapshot.ts"
cp "$W/bench/zz-base-streamingRow.ts" "$B/src/agent-session/acpmux/streamingRow.ts"
echo "base textOnlyRowPast refs: $(grep -c textOnlyRowPast "$B/src/agent-session/acpmux/App.tsx") fix: $(grep -c textOnlyRowPast "$W/src/agent-session/acpmux/App.tsx")"
parse() { grep -E -o 'COMPOSER-TYPING \[.*' | sed 's/^COMPOSER-TYPING //' | python3 -c '
import sys,json
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
for r in d: print("  ",r["mode"],"valid",r["valid"],"frame",r["to_frame_p95"],r["to_frame_p99"],"paint",r["to_paint_p95"],r["to_paint_p99"],"budget",r["budget_p95_ms"],r["budget_p99_ms"])'; }
A="--engines webkit --mode L3 --lengths 60 --keys 500 --gap 20 --repeat 3"
for r in $(seq 1 ${ROUNDS:-3}); do
  for arm in base fix fix base; do
    D=$W; [ $arm = base ] && D=$B
    echo "== round $r $arm load $(cut -d' ' -f1-3 /proc/loadavg)"
    (cd "$D" && bun bench/composer-typing.bench.ts $A 2>&1) | parse
    echo "   end load $(cut -d' ' -f1-3 /proc/loadavg)"
  done
done
