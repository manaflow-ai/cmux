#!/usr/bin/env bash
# ask-3c089caeef: before/after of racing the direct tailnet path (acpmux, Braid RFD 0164).
# A throwaway netlab on this machine: one network namespace stands in for the peer, with two
# links shaped by netem: the "tailnet direct" link (RTT 2*TAILNET_MS) and the link every
# other path takes (relay/ssh, RTT 2*OTHER_MS). No Tailscale, no real network or ACL is touched.
# Needs root (sudo -n) and a built acpmux test binary: BIN=path/to/acpmux-<hash>.
set -euo pipefail
BIN=${BIN:?acpmux test binary}
N=${N:-200}
TAILNET_MS=${TAILNET_MS:-4}
OTHER_MS=${OTHER_MS:-35}
NS=tnb-peer-$$
PORT=7801
busy=()
cleanup() {
  for p in "${busy[@]}"; do kill "$p" 2>/dev/null || true; done
  [ -n "${server:-}" ] && sudo -n kill "$server" 2>/dev/null || true
  sudo -n ip link del tnbt0-$$ 2>/dev/null || true
  sudo -n ip link del tnbr0-$$ 2>/dev/null || true
  sudo -n ip netns del "$NS" 2>/dev/null || true
}
trap cleanup EXIT
sudo -n ip netns add "$NS"
link() { # name host-ip peer-ip delay
  sudo -n ip link add "$1"0-$$ type veth peer name "$1"1-$$
  sudo -n ip link set "$1"1-$$ netns "$NS"
  sudo -n ip addr add "$2"/24 dev "$1"0-$$
  sudo -n ip link set "$1"0-$$ up
  sudo -n ip netns exec "$NS" ip addr add "$3"/24 dev "$1"1-$$
  sudo -n ip netns exec "$NS" ip link set "$1"1-$$ up
  sudo -n tc qdisc add dev "$1"0-$$ root netem delay "$4"ms
  sudo -n ip netns exec "$NS" tc qdisc add dev "$1"1-$$ root netem delay "$4"ms
}
link tnbt 10.77.1.1 10.77.1.2 "$TAILNET_MS"
link tnbr 10.77.2.1 10.77.2.2 "$OTHER_MS"
sudo -n ip netns exec "$NS" ip link set lo up
sudo -n ip netns exec "$NS" python3 -I -c '
import socket, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", '"$PORT"')); s.listen(512)
def serve(c):
    try:
        b = c.recv(1)
        if b: c.sendall(b)
    finally: c.close()
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
' & server=$!
sleep 1
run() { # label
  TAILNET_BENCH_TAILNET=10.77.1.2:$PORT TAILNET_BENCH_OTHER=10.77.2.2:$PORT TAILNET_BENCH_N=$N \
  TAILNET_BENCH_LABEL="$1" "$BIN" tailnet_race_netlab_bench --ignored --exact --nocapture \
    --test-threads 1 2>&1 | grep '^BENCH'
}
blackhole() { sudo -n tc qdisc change dev "$1"0-$$ root netem delay "$2"ms loss 100%; }
restore() { sudo -n tc qdisc change dev "$1"0-$$ root netem delay "$2"ms; }
echo "netlab: tailnet RTT $((2*TAILNET_MS))ms, other paths RTT $((2*OTHER_MS))ms, n=$N, nproc=$(nproc)"
run steady
blackhole tnbt "$TAILNET_MS"; run "after-change:tailnet-blackholed"; restore tnbt "$TAILNET_MS"
blackhole tnbr "$OTHER_MS"; run "after-change:relay-blackholed"; restore tnbr "$OTHER_MS"
for _ in $(seq $(( $(nproc) * 2 ))); do (while :; do :; done) & busy+=($!); done
echo "Duress: $(( $(nproc) * 2 )) busy loops on $(nproc) cpus, load1 $(cut -d' ' -f1 /proc/loadavg)"
run duress
echo "Duress: load1 at end $(cut -d' ' -f1 /proc/loadavg)"
