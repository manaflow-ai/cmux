#!/bin/bash
cd "$(dirname "$0")/.."
echo "== HOST $(hostname) nproc=$(nproc)"; uptime; lscpu | grep -E "Model name|^CPU\(s\)|Thread"; free -g | head -2
./node_modules/.bin/playwright install webkit >/dev/null 2>&1 || true
for i in 1 2; do echo "== FLOOR $i"; bun bench/zz-floor-tmp.ts 2>&1 | tail -2; done
A="--engines webkit --mode L0,L3 --lengths 60 --keys 500 --gap 20 --repeat 3"
for v in before ""; do f=bench/composer-typing${v:+-$v}.bench.ts; echo "== RUN ${v:-after}"; uptime
 bun $f $A 2>&1 | grep -o 'COMPOSER-TYPING \[.*' | sed 's/^COMPOSER-TYPING //' | python3 -c '
import sys,json
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
for r in d: print(r["engine"],r["mode"],"valid",r["valid"],"frame",r["to_frame_p95"],r["to_frame_p99"],"paint",r["to_paint_p95"],r["to_paint_p99"],"refresh",r["display_refresh_ms"],"budget",r["budget_p95_ms"],r["budget_p99_ms"],"late",round(r["driver_late_p95_ms"],1))'
done
