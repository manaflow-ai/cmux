#!/bin/bash
cd "$(dirname "$0")/.."
echo "== HOST $(hostname) nproc=$(nproc)"; uptime; lscpu | grep -E "Model name|^CPU\(s\)"
./node_modules/.bin/playwright install webkit >/dev/null 2>&1 || true
parse() { grep -o 'COMPOSER-TYPING \[.*' | sed 's/^COMPOSER-TYPING //' | python3 -c '
import sys,json
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
for r in d: print(r["engine"],r["mode"],"valid",r["valid"],"frame",r["to_frame_p95"],r["to_frame_p99"],"paint",r["to_paint_p95"],r["to_paint_p99"],"budget",r["budget_p95_ms"],r["budget_p99_ms"])'; }
A="--engines webkit --lengths 60 --keys 500 --gap 20 --repeat 3"
echo "== SPLIT L0,L1,L3"; bun bench/composer-typing.bench.ts $A --mode L0,L1,L3 2>&1 | parse
echo "== L3 cost probe"; bun bench/composer-typing.bench.ts $A --mode L3 --probe bench/zz-cost.js > /tmp/l3cost.log 2>&1; parse < /tmp/l3cost.log; grep '^PROBE' /tmp/l3cost.log | head -c 6000; echo
