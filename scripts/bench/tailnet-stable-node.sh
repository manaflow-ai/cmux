#!/usr/bin/env bash
# tailnet-stable-node: one stable "cmux" tailnet node in front of two private VM namespaces (A and B), measured while
# the VM behind it moves. Everything is local to this host: a headscale control and its embedded DERP on a bridge in
# the host namespace, and one tailscaled per namespace on its own socket and state. It never touches a real tailnet
# or any tailscaled that is already running here.
#
#   sudo scripts/bench/tailnet-stable-node.sh [MOVES=20] [OUT=a new mktemp folder]
#
# Namespaces: bclient (the user's tailnet node), bcmux (the stable node: tailscaled plus the front proxy, forwards
# between the tailnet and a private bridge), bvma and bvmb (the VMs, 10.50.0.11 and .12, echo on :7001).
# Variant v1: bcmux advertises 10.50.0.0/24, the client reaches a VIP 10.50.0.100 that moves A -> B by address moves
# plus gratuitous ARP. Variant v2: the default front, a TCP proxy on bcmux's tailnet address whose backend leg moves
# A -> B (SIGUSR1). Rows and the client's tailnet view before and after are printed as one JSON line:
#   TNSB-RUN {"schema": "tailnet-stable-node-run.v1", ...}
set -euo pipefail
SELF=$(readlink -f "$0")
HERE=$(dirname "$SELF")
if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$SELF" "$@"; fi
MOVES=${1:-20}
OUT=${2:-$(mktemp -d /tmp/tnsb.XXXXXX)}  # a fresh folder of this run, never a guessable name
GAP=${GAP:-3}
HS_VER=0.27.1
PY=(python3 -I "$HERE/tailnet_bench.py")
mkdir -p "$OUT"
echo "out: $OUT" >&2
cd "$OUT"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq >/dev/null
apt-get install -y -qq iproute2 iputils-arping iptables curl ca-certificates python3 >/dev/null

# headscale and tailscale, unpacked under OUT (no system install, nothing on PATH)
if [ ! -x "$OUT/hs/usr/bin/headscale" ]; then
  curl -fsSL -o "$OUT/headscale.deb" \
    "https://github.com/juanfont/headscale/releases/download/v${HS_VER}/headscale_${HS_VER}_linux_amd64.deb"
  mkdir -p "$OUT/hs"
  dpkg-deb -x "$OUT/headscale.deb" "$OUT/hs"
fi
HS="$OUT/hs/usr/bin/headscale"
if [ ! -x "$OUT/tailscale/tailscaled" ]; then
  TGZ=$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["Tarballs"]["amd64"])')
  curl -fsSL -o "$OUT/ts.tgz" "https://pkgs.tailscale.com/stable/$TGZ"
  mkdir -p "$OUT/tailscale"
  tar -xzf "$OUT/ts.tgz" -C "$OUT/tailscale" --strip-components=1
fi
TS="$OUT/tailscale/tailscale"
TSD="$OUT/tailscale/tailscaled"

cleanup() {
  for p in $(jobs -p); do kill "$p" 2>/dev/null || true; done
  for n in bclient bcmux bvma bvmb; do ip netns del "$n" 2>/dev/null || true; done
  ip link del br-ul 2>/dev/null || true
}
trap cleanup EXIT

# --- the underlay: br-ul in the host namespace; bclient 10.99.0.10 and bcmux 10.99.0.2 on it
for n in bclient bcmux bvma bvmb; do ip netns del "$n" 2>/dev/null || true; ip netns add "$n"; done
ip link add br-ul type bridge
ip link set br-ul up
ip addr add 10.99.0.1/24 dev br-ul
for pair in "bclient 10.99.0.10" "bcmux 10.99.0.2"; do
  set -- $pair
  ip link add "ul-$1" type veth peer name eth0 netns "$1"
  ip link set "ul-$1" master br-ul
  ip link set "ul-$1" up
  ip -n "$1" link set lo up
  ip -n "$1" addr add "$2/24" dev eth0
  ip -n "$1" link set eth0 up
  ip -n "$1" route add default via 10.99.0.1
done

# --- the private network behind bcmux: br-priv 10.50.0.1, VMs A and B on it
ip -n bcmux link add br-priv type bridge
ip -n bcmux link set br-priv up
ip -n bcmux addr add 10.50.0.1/24 dev br-priv
ip netns exec bcmux sysctl -qw net.ipv4.ip_forward=1
for pair in "bvma 10.50.0.11" "bvmb 10.50.0.12"; do
  set -- $pair
  ip link add "pr-$1" type veth peer name eth0 netns "$1"
  ip link set "pr-$1" netns bcmux
  ip -n bcmux link set "pr-$1" master br-priv
  ip -n bcmux link set "pr-$1" up
  ip -n "$1" link set lo up
  ip -n "$1" addr add "$2/24" dev eth0
  ip -n "$1" link set eth0 up
  ip -n "$1" route add default via 10.50.0.1
done
ip -n bvma addr add 10.50.0.100/24 dev eth0  # the VIP starts on A

# --- headscale on the underlay, DERP included
cat > "$OUT/hs.yaml" <<EOF
server_url: http://10.99.0.1:8080
listen_addr: 10.99.0.1:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: true
noise:
  private_key_path: $OUT/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 999
    region_code: bench
    region_name: bench
    stun_listen_addr: 10.99.0.1:3478
    private_key_path: $OUT/derp_server_private.key
    ipv4: 10.99.0.1
  urls: []
  paths: []
  auto_update_enabled: false
  update_frequency: 24h
disable_check_updates: true
ephemeral_node_inactivity_timeout: 30m
database:
  type: sqlite
  sqlite:
    path: $OUT/db.sqlite
dns:
  magic_dns: false
  base_domain: bench.internal
  override_local_dns: false
  nameservers:
    global: [1.1.1.1]
unix_socket: $OUT/headscale.sock
log:
  level: warn
EOF
"$HS" -c "$OUT/hs.yaml" serve >"$OUT/headscale.log" 2>&1 &
for _ in $(seq 1 100); do curl -fsS http://10.99.0.1:8080/health >/dev/null 2>&1 && break; sleep 0.2; done
HSC="$HS -c $OUT/hs.yaml"
$HSC users create bench >/dev/null
USER_ID=$($HSC users list -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
KEY=$($HSC preauthkeys create -u "$USER_ID" --reusable -e 2h -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')

# --- tailscaled per namespace (its own socket and state; never the runner's own daemon)
tsd() {
  ip netns exec "$1" "$TSD" --state="$OUT/$1.state" --socket="$OUT/$1.sock" --port=0 \
    >"$OUT/$1.tsd.log" 2>&1 &
  for _ in $(seq 1 100); do [ -S "$OUT/$1.sock" ] && break; sleep 0.1; done
}
tsctl() { ns=$1; shift; ip netns exec "$ns" "$TS" --socket="$OUT/$ns.sock" "$@"; }
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }

tsd bcmux
t=$(date +%s%N)
tsctl bcmux up --login-server=http://10.99.0.1:8080 --authkey="$KEY" --hostname=cmux \
  --advertise-routes=10.50.0.0/24 --reset
CONNECT_CMUX_MS=$(ms "$t")
NODE_ID=$($HSC nodes list -o json | python3 -c \
  'import json,sys; print([n["id"] for n in json.load(sys.stdin) if "cmux" in (n.get("given_name"), n.get("name"))][0])')
$HSC nodes approve-routes --identifier "$NODE_ID" --routes 10.50.0.0/24 >/dev/null

tsd bclient
t=$(date +%s%N)
tsctl bclient up --login-server=http://10.99.0.1:8080 --authkey="$KEY" --hostname=client --accept-routes --reset
CONNECT_CLIENT_MS=$(ms "$t")
CMUX_IP=$(tsctl bcmux ip -4 | head -1)

# the route from the approved advertisement reaches the client
t=$(date +%s%N)
for _ in $(seq 1 300); do
  ip netns exec bclient ip route show table 52 2>/dev/null | grep -q '10.50.0.0/24' && break
  sleep 0.2
done
ROUTE_VISIBLE_MS=$(ms "$t")

# DERP -> direct: the first pong's path, then time until the client's path to cmux is direct
FIRST=$(tsctl bclient ping -c 1 --timeout 10s "$CMUX_IP" 2>&1 | tail -1 || true)
t=$(date +%s%N)
tsctl bclient ping --until-direct --timeout 60s "$CMUX_IP" >"$OUT/ping-direct.txt" 2>&1 || true
DERP_TO_DIRECT_MS=$(ms "$t")
FINAL=$(tail -1 "$OUT/ping-direct.txt" | tr -d '"')

tsctl bclient status --json >"$OUT/status-before.json"

# --- the VMs' echo servers (TCP and UDP on :7001) and the one front proxy
for vm in bvma bvmb; do
  ip netns exec "$vm" "${PY[@]}" serve --port 7001 >"$OUT/$vm.echo.log" 2>&1 &
done
sleep 1
DUR=$(( MOVES * GAP + 8 ))

# --- v1: the client talks to the VIP through the subnet route; the VIP moves A <-> B
: >"$OUT/moves-v1.jsonl"
ip netns exec bclient "${PY[@]}" client --proto tcp --target 10.50.0.100:7001 --duration "$DUR" \
  --out "$OUT/v1-tcp.jsonl" --idle 1.0 &
ip netns exec bclient "${PY[@]}" client --proto udp --target 10.50.0.100:7001 --duration "$DUR" \
  --out "$OUT/v1-udp.jsonl" --idle 1.0 &
sleep 3
cur=bvma
nxt=bvmb
for _ in $(seq 1 "$MOVES"); do
  sleep "$GAP"
  t=$(date +%s%N)
  ip netns exec "$cur" ip addr del 10.50.0.100/24 dev eth0
  ip netns exec "$nxt" ip addr add 10.50.0.100/24 dev eth0
  ip netns exec "$nxt" arping -U -c 3 -I eth0 10.50.0.100 >/dev/null 2>&1 || true
  echo "{\"t_ns\": $t, \"to\": \"$nxt\"}" >>"$OUT/moves-v1.jsonl"
  cur=$nxt
  if [ "$nxt" = bvma ]; then nxt=bvmb; else nxt=bvma; fi
done
wait

# --- v2: the client talks to the tailnet front on bcmux; the front's backend leg moves A <-> B
echo "10.50.0.11:7001" >"$OUT/upstream"
ip netns exec bcmux "${PY[@]}" proxy --listen 0.0.0.0:7001 --upstream-file "$OUT/upstream" \
  --pidfile "$OUT/proxy.pid" >"$OUT/proxy.log" 2>&1 &
for _ in $(seq 1 50); do [ -s "$OUT/proxy.pid" ] && break; sleep 0.1; done
: >"$OUT/moves-v2.jsonl"
ip netns exec bclient "${PY[@]}" client --proto tcp --target "$CMUX_IP:7001" --duration "$DUR" \
  --out "$OUT/v2-tcp.jsonl" --idle 1.0 &
sleep 3
cur=10.50.0.11
nxt=10.50.0.12
for _ in $(seq 1 "$MOVES"); do
  sleep "$GAP"
  t=$(date +%s%N)
  echo "$nxt:7001" >"$OUT/upstream.new"
  mv "$OUT/upstream.new" "$OUT/upstream"
  kill -USR1 "$(cat "$OUT/proxy.pid")"
  echo "{\"t_ns\": $t, \"to\": \"$nxt\"}" >>"$OUT/moves-v2.jsonl"
  cur=$nxt
  if [ "$nxt" = 10.50.0.11 ]; then nxt=10.50.0.12; else nxt=10.50.0.11; fi
done
wait

tsctl bclient status --json >"$OUT/status-after.json"

# --- one JSON line: the rows' source
cat >"$OUT/meta.json" <<EOF
{"moves": $MOVES, "gap_s": $GAP, "connect_cmux_ms": $CONNECT_CMUX_MS, "connect_client_ms": $CONNECT_CLIENT_MS,
 "route_visible_ms": $ROUTE_VISIBLE_MS, "derp_to_direct_ms": $DERP_TO_DIRECT_MS,
 "first_pong": "$(echo "$FIRST" | tr -d '"')", "final_path": "$FINAL"}
EOF
"${PY[@]}" summary --dir "$OUT" | sed 's/^/TNSB-RUN /'
