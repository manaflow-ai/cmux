#!/usr/bin/env bash
# Braid slice B3 before/after (RFD 0164): a reconnect after the live path dies, with and without
# the standby pool. Two network namespaces joined by a veth: IPv4 25 ms each way (50 ms RTT),
# IPv6 500 ms out and 25 back (525 ms RTT), so the first dial's IPv6 attempt loses to IPv4 (which
# starts at the 400 ms stagger) but still connects 75 ms later: the loser the pool keeps. The
# listener holds every connection open. Each run is a fresh bench process: one first dial, then
# the winner's family black-holed and one reconnect (examples/braid_standby_bench.rs).
# Usage: sudo bench/netns-standby.sh BENCH_BINARY [N]. Makes and removes only its own namespaces
# (braid-c, braid-s) and /etc/netns/braid-c. For a VM or CI host, never a person's machine.
set -euo pipefail
bin=${1:?bench binary}; n=${2:-20}
c=braid-c; s=braid-s
cleanup() { ip netns del "$c" 2>/dev/null || true; ip netns del "$s" 2>/dev/null || true; rm -f /etc/netns/$c/hosts; rmdir /etc/netns/$c 2>/dev/null || true; }
trap cleanup EXIT
cleanup
ip netns add "$c"; ip netns add "$s"
ip link add braid-vc type veth peer name braid-vs
ip link set braid-vc netns "$c"; ip link set braid-vs netns "$s"
for ns in "$c" "$s"; do ip -n "$ns" link set lo up; done
ip -n "$c" addr add 10.77.0.1/24 dev braid-vc; ip -n "$c" addr add fd77::1/64 dev braid-vc nodad
ip -n "$s" addr add 10.77.0.2/24 dev braid-vs; ip -n "$s" addr add fd77::2/64 dev braid-vs nodad
ip -n "$c" link set braid-vc up; ip -n "$s" link set braid-vs up
# Client egress: IPv6 to band 1 (500 ms), the rest to band 2 (25 ms).
ip netns exec "$c" tc qdisc add dev braid-vc root handle 1: prio bands 2 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
ip netns exec "$c" tc qdisc add dev braid-vc parent 1:1 handle 10: netem delay 500ms
ip netns exec "$c" tc qdisc add dev braid-vc parent 1:2 handle 20: netem delay 25ms
ip netns exec "$c" tc filter add dev braid-vc parent 1: protocol ipv6 prio 1 matchall flowid 1:1
ip netns exec "$s" tc qdisc add dev braid-vs root netem delay 25ms
mkdir -p /etc/netns/$c
printf 'fd77::2 braid-peer\n10.77.0.2 braid-peer\n' > /etc/netns/$c/hosts
ip netns exec "$s" python3 -c '
import socket
s=socket.socket(socket.AF_INET6); s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("::",7443)); s.listen(512)
held=[]
while True:
    a,_=s.accept(); held.append(a)' &
srv=$!
trap 'kill $srv 2>/dev/null || true; cleanup' EXIT
sleep 0.3
for arm in 0 1; do
  echo "== standby=$arm"
  for _ in $(seq "$n"); do ip netns exec "$c" env CMUX_BRAID_STANDBY="$arm" "$bin" braid-peer 7443; done | tee /tmp/braid-standby-$arm.jsonl | tail -1
  python3 - "$arm" <<'PY'
import json, sys
rows=[json.loads(l) for l in open(f"/tmp/braid-standby-{sys.argv[1]}.jsonl")]
ok=[r for r in rows if r["reconnect_ok"]]
t=sorted(r["reconnect_ms"] for r in ok); f=sorted(r["first_ms"] for r in rows)
at=lambda v,p: v[min(len(v)-1, ((len(v)-1)*p+50)//100)] if v else float("nan")
print(json.dumps({"standby": sys.argv[1]=="1", "n": len(rows), "reconnect_failed": len(rows)-len(ok),
  "reconnect_p50_ms": at(t,50), "reconnect_p95_ms": at(t,95), "reconnect_mean_ms": round(sum(t)/len(t),1) if t else None,
  "first_p50_ms": at(f,50), "via": sorted({r["reconnect_via"] for r in ok})}))
PY
done
