#!/bin/bash
cd "$(dirname "$0")/.."
echo "== HOST $(hostname) nproc=$(nproc)"; uptime
./node_modules/.bin/playwright install webkit >/dev/null 2>&1 || true
parse() { grep -o 'COMPOSER-TYPING \[.*' | sed 's/^COMPOSER-TYPING //' | python3 -c '
import sys,json
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
for r in d: print(r["mode"],"valid",r["valid"],"frame",r["to_frame_p95"],r["to_frame_p99"],"paint",r["to_paint_p95"],r["to_paint_p99"],"budget",r["budget_p95_ms"],r["budget_p99_ms"])'; }
A="--engines webkit --mode L3 --lengths 60 --keys 500 --gap 20 --repeat 3"
for v in ${VARIANTS:-base nooff noedges nowatch noanim combo base}; do
  echo "== $v $(uptime | sed 's/.*average//')"
  P=""; [ "$v" != base ] && P="--probe bench/zz-v-$v.js"
  bun bench/composer-typing.bench.ts $A $P 2>&1 | parse
done
