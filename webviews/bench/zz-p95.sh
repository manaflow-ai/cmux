#!/bin/bash
cd "$(dirname "$0")/.."
echo "== HOST $(hostname) nproc=$(nproc)"; uptime
./node_modules/.bin/playwright install webkit >/dev/null 2>&1 || true
parse() { tee -a /tmp/zz-raw.log | grep -E -o 'COMPOSER-TYPING \[.*|STREAM-SPANS .*|PROBE .*' | while IFS= read -r line; do
  case "$line" in STREAM-SPANS*|PROBE*) echo "${line:0:3500}";; *) echo "$line" | sed 's/^COMPOSER-TYPING //' | python3 -c '
import sys,json
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
for r in d: print(r["mode"],"valid",r["valid"],"frame",r["to_frame_p95"],r["to_frame_p99"],"paint",r["to_paint_p95"],r["to_paint_p99"],"budget",r["budget_p95_ms"],r["budget_p99_ms"],"pane",r.get("pane"),"transcript",r.get("transcript"),"busiest",json.dumps(r.get("busiest"))[:300])';; esac; done; }
A="--engines webkit --mode L3 --lengths 60 --keys 500 --gap 20 --repeat 3"
for v in ${VARIANTS:-base noshimmer noanims base noshimmer noanims}; do
  echo "== $v load $(cut -d' ' -f1-3 /proc/loadavg)"
  P="--probe bench/zz-${PFX:-v}-$v.js"; [ "${PFX:-v}" = v ] && [ "$v" = base ] && P=""
  bun bench/composer-typing.bench.ts $A $P 2>&1 | parse
  echo "   end load $(cut -d' ' -f1-3 /proc/loadavg)"
done
