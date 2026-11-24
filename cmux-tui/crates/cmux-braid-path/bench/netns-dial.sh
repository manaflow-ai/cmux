#!/usr/bin/env bash
# Braid slice B1 before/after (RFD 0164): two network namespaces joined by a veth with netem
# 25 ms each way (50 ms RTT), a dual-stack listener in one, the hedged dial bench in the other.
# Scenarios:
#   v6-blackhole  the name resolves to IPv6 and IPv4; IPv6 SYNs are dropped
#   tuple-25      IPv4 only; 1 in 4 source ports (5-tuples) black-holed by a hash
# Usage: sudo bench/netns-dial.sh BENCH_BINARY [N]. Makes and removes only its own namespaces
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
ip netns exec "$c" tc qdisc add dev braid-vc root netem delay 25ms
ip netns exec "$s" tc qdisc add dev braid-vs root netem delay 25ms
mkdir -p /etc/netns/$c
ip netns exec "$s" python3 -c '
import socket
s=socket.socket(socket.AF_INET6); s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("::",7443)); s.listen(512)
while True:
    a,_=s.accept(); a.close()' &
srv=$!
trap 'kill $srv 2>/dev/null || true; cleanup' EXIT
sleep 0.3
run() { # scenario arm
  echo "== $1 last_good=$2"
  ip netns exec "$c" env CMUX_BRAID_LAST_GOOD="$2" "$bin" braid-peer 7443 "$n" | tail -1
}
printf 'fd77::2 braid-peer\n10.77.0.2 braid-peer\n' > /etc/netns/$c/hosts
ip netns exec "$s" ip6tables -A INPUT -p tcp --dport 7443 -j DROP
[ "${SKIP_V6:-0}" = 1 ] || { run v6-blackhole 0; run v6-blackhole 1; }
ip netns exec "$s" ip6tables -F INPUT
printf '10.77.0.2 braid-peer\n' > /etc/netns/$c/hosts
ip netns exec "$s" nft -f - <<'NFT'
table ip braid {
  chain input {
    type filter hook input priority 0;
    tcp dport 7443 jhash ip saddr . tcp sport mod 4 seed 0x5eed == 0 drop
  }
}
NFT
run tuple-25 0; run tuple-25 1
