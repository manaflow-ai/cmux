#!/usr/bin/env bash
# The inference gateway's first model call to the sr2 pool, from a cold connection against one the gateway warmed
# at start (cmux-tui/crates/cmux-tui/src/cli/inference_gateway.rs `Provider::warm`): N pairs of one Claude Code
# style streaming call, cold (a fresh curl, new TCP and tailnet path) and warm (the same curl first sends the
# warm-up, then the call rides that socket). Time to the response head, which on sr2 is the first token.
# Run from any host on the tailnet (a lane VM, or the probe Mac to see its own path):
#   scripts/measure/gateway-upstream-warm.sh N POOL_URL   (POOL_URL: the gateway's --upstream base)
# Output: GATEWAY-WARM lines, one per side: n, first-token p10/p50/p90 ms, connect p50 ms.
set -euo pipefail
n="${1:-20}"
url="${2:?usage: gateway-upstream-warm.sh N POOL_URL}"
body='{"model":"claude-haiku-4-5","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"hi"}]}'
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
headers=(-H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -H 'x-api-key: tailnet')
for _ in $(seq 1 "$n"); do
  sid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  printf 'cold %s\n' "$(curl -s -N -m 40 -o /dev/null -w '%{time_connect} %{time_starttransfer}' \
    "$url/v1/messages" "${headers[@]}" -H "x-claude-code-session-id: $sid" -d "$body")" >>"$out"
  sid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
  printf 'warm %s\n' "$(curl -s -N -m 40 -o /dev/null -w '%{time_connect} %{time_starttransfer}\n' -I "$url" \
    --next -s -N -m 40 -o /dev/null -w '%{time_connect} %{time_starttransfer}' \
    "$url/v1/messages" "${headers[@]}" -H "x-claude-code-session-id: $sid" -d "$body" | tail -1)" >>"$out"
done
python3 -I - "$out" <<'PY'
import statistics, sys
rows = {"cold": [], "warm": []}
for line in open(sys.argv[1]):
    side, connect, first = line.split()
    rows[side].append((float(connect) * 1000, float(first) * 1000))
for side, got in rows.items():
    first = sorted(f for _, f in got)
    at = lambda q: first[min(len(first) - 1, int(len(first) * q))]
    print(f"GATEWAY-WARM {side} n={len(first)} first_token_ms p10={at(.1):.0f} p50={statistics.median(first):.0f} "
          f"p90={at(.9):.0f} connect_p50_ms={statistics.median(c for c, _ in got):.1f}")
PY
