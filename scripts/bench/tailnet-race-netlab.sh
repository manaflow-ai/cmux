#!/usr/bin/env bash
# ask-3c089caeef: before/after of racing the direct tailnet path (acpmux, Braid RFD 0164).
# A throwaway netlab on loopback, no root: one echo server per link adds the link's round trip
# (RTT_MS once for the handshake, once for the echo), so the "tailnet direct" link answers in
# 2*TAILNET_RTT and the link every other path takes (relay/ssh) in 2*OTHER_RTT. A black-holed
# link accepts and never answers (a network change that killed it). No Tailscale, no real
# network or ACL is touched. BIN=path/to/acpmux-<hash> (the lib test binary).
set -euo pipefail
BIN=${BIN:?acpmux test binary}
N=${N:-200}
TAILNET_RTT=${TAILNET_RTT:-8}
OTHER_RTT=${OTHER_RTT:-70}
busy=()
cleanup() { for p in "${busy[@]}" ${server:-}; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
python3 -I -c '
import asyncio, sys
links = {7811: float(sys.argv[1]) / 1000, 7812: float(sys.argv[2]) / 1000, 7813: None, 7814: None}
async def main():
    async def serve(port, rtt, r, w):
        if rtt is None:
            await asyncio.sleep(3600); return
        await asyncio.sleep(rtt)
        b = await r.read(1)
        await asyncio.sleep(rtt)
        w.write(b); await w.drain(); w.close()
    for port, rtt in links.items():
        await asyncio.start_server(lambda r, w, p=port, t=rtt: serve(p, t, r, w), "127.0.0.1", port, backlog=1024)
    await asyncio.sleep(10**9)
asyncio.run(main())
' "$TAILNET_RTT" "$OTHER_RTT" & server=$!
sleep 1
run() { # label tailnet-port other-port
  TAILNET_BENCH_TAILNET=127.0.0.1:$2 TAILNET_BENCH_OTHER=127.0.0.1:$3 TAILNET_BENCH_N=$N \
  TAILNET_BENCH_LABEL="$1" "$BIN" tailnet_race_netlab_bench --ignored --exact --nocapture \
    --test-threads 1 2>&1 | grep '^BENCH'
}
echo "netlab: tailnet RTT ${TAILNET_RTT}ms, other paths RTT ${OTHER_RTT}ms, n=$N, nproc=$(nproc)"
run steady 7811 7812
run "after-change:tailnet-blackholed" 7813 7812
run "after-change:relay-blackholed" 7811 7814
for _ in $(seq $(( $(nproc) * 2 ))); do (while :; do :; done) & busy+=($!); done
sleep 2
echo "Duress: $(( $(nproc) * 2 )) busy loops on $(nproc) cpus, load1 $(cut -d' ' -f1 /proc/loadavg)"
run duress 7811 7812
echo "Duress: load1 at end $(cut -d' ' -f1 /proc/loadavg)"
