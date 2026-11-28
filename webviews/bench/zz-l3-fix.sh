#!/bin/bash
cd "$(dirname "$0")/.."
C=src/agent-session/acpmux/conversation/conversation.css
echo "== HOST $(hostname) nproc=$(nproc)"; uptime
./node_modules/.bin/playwright install webkit >/dev/null 2>&1 || true
parse() { tee /tmp/zzrun.log | grep -o 'COMPOSER-TYPING \[.*' | sed 's/^COMPOSER-TYPING //' | python3 -c '
import sys,json
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
for r in d: print(r["mode"],"valid",r["valid"],"frame",r["to_frame_p95"],r["to_frame_p99"],"paint",r["to_paint_p95"],r["to_paint_p99"],"budget",r["budget_p95_ms"],r["budget_p99_ms"])'; grep -oE 'minimal_frac[^}]*' /tmp/zzrun.log | head -3; }
A="--engines webkit --mode L3 --lengths 60 --keys 500 --gap 20 --repeat 3"
for v in ${VARIANTS:-base fix base fix base fix}; do
  cp bench/zz-var/$v/conversation.css $C; cp bench/zz-var/$v/Markdown.tsx src/agent-session/acpmux/conversation/Markdown.tsx
  echo "== $v load$(uptime | sed 's/.*average://')"
  bun bench/composer-typing.bench.ts $A ${PROBE:+--probe $PROBE} 2>&1 | parse
done
cp bench/zz-var/all/conversation.css $C; cp bench/zz-var/all/Markdown.tsx src/agent-session/acpmux/conversation/Markdown.tsx
