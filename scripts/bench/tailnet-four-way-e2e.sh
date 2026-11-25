#!/usr/bin/env bash
# tailnet-four-way-e2e: the stable node (ours) against a plain tailnet node, each on the direct path and on forced
# DERP, on a throwaway headscale tailnet in docker. Never the host's tailscaled or a real tailnet: every node is a
# container on a private docker network with a label unique to this run; cleanup removes only those.
#
#   arms:  plain-direct   client -> plain node (tailscale, TUN), UDP open
#          plain-derp     client -> plain node, UDP dropped on the client (no direct path: DERP relay)
#          front-direct   client -> our front (stable_node front, tsnet), UDP open
#          front-derp     client -> our front, UDP dropped on the client ("our relay")
#   per arm: a TCP echo stream through the client's SOCKS5 (localhost:1055) for DUR seconds.
#     T=8 s  network change: all UDP from the client dropped
#     T=12 s network restored; time_to_direct_ms = `tailscale ping --until-direct` after the restore
#     T=16 s front arms only: placement moves workspace main from backend-a to backend-b
#   Forced DERP is iptables on the client: a peer with no UDP path can only be reached over DERP.
#   Load1 is read on the host at each arm's start and end; each arm's row carries both.
#
# Usage: tailnet-four-way-e2e.sh STABLE_NODE_BINARY [OUT_DIR]
# env: RUNTIME_IMAGE (ubuntu:24.04), TAILSCALE_IMAGE (tailscale/tailscale:stable), HEADSCALE_IMAGE
#      (headscale/headscale:0.27.1), DUR (24), KEEP=1 keeps the containers and the work dir.
# Output: one line `TFW-RUN {...}` (schema tailnet-four-way-run.v1), plus the per-arm JSONL in OUT_DIR.
set -euo pipefail

BIN=${1:?usage: tailnet-four-way-e2e.sh STABLE_NODE_BINARY [OUT_DIR]}
BIN=$(readlink -f "$BIN")
HERE=$(cd "$(dirname "$0")" && pwd)
PY_HELPER=$HERE/tailnet_bench.py
HEADSCALE_IMAGE=${HEADSCALE_IMAGE:-headscale/headscale:0.27.1}
TAILSCALE_IMAGE=${TAILSCALE_IMAGE:-tailscale/tailscale:stable}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-ubuntu:24.04}
DUR=${DUR:-24}
RUN_ID="cmux-four-way-$(date +%s)-$$-$RANDOM"
LABEL="cmux.four-way-e2e.run=$RUN_ID"
NET="$RUN_ID"
HS="$RUN_ID-headscale"
FRONT="$RUN_ID-front"
BA="$RUN_ID-backend-a"
BB="$RUN_ID-backend-b"
PLAIN="$RUN_ID-plain"
CLIENT="$RUN_ID-client"
VOL="$RUN_ID-state"

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  echo "FAIL setup: cannot reach docker (neither docker nor sudo -n docker)" >&2
  exit 2
fi
d() { "${DOCKER[@]}" "$@"; }

OUT=${2:-/tmp/tfw-$RUN_ID}
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmux-four-way.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/keys"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
load1() { cut -d' ' -f1 /proc/loadavg; }

cleanup() {
  local rc=$?
  if [[ ${KEEP:-0} == 1 ]]; then
    log "KEEP=1: leaving run $RUN_ID (label $LABEL), work dir $WORK"
    return
  fi
  local ids
  ids=$(d ps -aq --filter "label=$LABEL" 2>/dev/null || true)
  [[ -n $ids ]] && d rm -fv $ids >/dev/null 2>&1 || true
  ids=$(d network ls -q --filter "label=$LABEL" 2>/dev/null || true)
  [[ -n $ids ]] && d network rm $ids >/dev/null 2>&1 || true
  ids=$(d volume ls -q --filter "label=$LABEL" 2>/dev/null || true)
  [[ -n $ids ]] && d volume rm $ids >/dev/null 2>&1 || true
  rm -rf -- "$WORK"
  log "cleaned up run $RUN_ID"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- headscale (same config as stable-node-e2e.sh)
cat >"$WORK/config.yaml" <<'EOF'
server_url: http://headscale:8080
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential
derp:
  server:
    enabled: true
    region_id: 999
    region_code: headscale
    region_name: Headscale Embedded DERP
    verify_clients: true
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
    ipv4: ""
    ipv6: ""
  urls: []
  paths: []
  auto_update_enabled: false
  update_frequency: 24h
disable_check_updates: true
ephemeral_node_inactivity_timeout: 66s
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true
log:
  level: info
  format: text
policy:
  mode: file
  path: /etc/headscale/policy.json
dns:
  magic_dns: true
  base_domain: test.cmux
  override_local_dns: false
  nameservers:
    global: []
    split: {}
  search_domains: []
  extra_records: []
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
logtail:
  enabled: false
randomize_client_port: false
EOF
cat >"$WORK/policy.json" <<'EOF'
{ "acls": [{ "action": "accept", "src": ["*"], "dst": ["*:*"] }] }
EOF

log "run $RUN_ID: headscale $HEADSCALE_IMAGE, tailscale $TAILSCALE_IMAGE; load1 at start $(load1)"
LOAD_START=$(load1)
d network create --label "$LABEL" "$NET" >/dev/null
d volume create --label "$LABEL" "$VOL" >/dev/null
d create --name "$HS" --label "$LABEL" --network "$NET" --network-alias headscale \
  "$HEADSCALE_IMAGE" serve >/dev/null
mkdir -p "$WORK/etc-headscale"
cp "$WORK/config.yaml" "$WORK/policy.json" "$WORK/etc-headscale/"
d cp "$WORK/etc-headscale/." "$HS:/etc/headscale/"
d start "$HS" >/dev/null
hs() { d exec "$HS" headscale "$@"; }
for _ in $(seq 1 60); do hs users list >/dev/null 2>&1 && break; sleep 0.5; done
hs users list >/dev/null 2>&1 || { d logs "$HS" 2>&1 | tail -30 >&2; echo "FAIL setup: headscale did not come up" >&2; exit 1; }
hs users create cmux >/dev/null
USER_ID=$(hs users list -o json | jq -r '.[] | select(.name=="cmux") | .id')
( umask 077; hs preauthkeys create --user "$USER_ID" --reusable --expiration 2h -o json | jq -r .key >"$WORK/keys/reusable" )
[[ -s $WORK/keys/reusable ]] || { echo "FAIL setup: could not mint a pre-auth key" >&2; exit 1; }
chmod 644 "$WORK/keys/reusable"

# ---------------------------------------------------------------- backends, the front, the plain node, the client
run_bin() { # run_bin NAME ALIAS ARGS...  (no tailnet: plain docker network)
  local name=$1 alias=$2; shift 2
  d run -d --name "$name" --label "$LABEL" --network "$NET" --network-alias "$alias" \
    -v "$BIN:/usr/local/bin/stable_node:ro" "$RUNTIME_IMAGE" /usr/local/bin/stable_node "$@" >/dev/null
}
run_bin "$BA" backend-a echo A 0.0.0.0:7000
run_bin "$BB" backend-b echo B 0.0.0.0:7000

# our front: a tsnet node named cmux, tailnet port 7000 -> workspace main -> backend-a
FRONT_START=$(date +%s%N)
d run -d --name "$FRONT" --label "$LABEL" --network "$NET" --network-alias front \
  --cap-add NET_ADMIN -e TS_DEBUG_USE_DERP_HTTP=1 \
  -v "$BIN:/usr/local/bin/stable_node:ro" \
  -v "$WORK/keys/reusable:/run/cmux-tailnet/authkey:ro" \
  -v "$VOL:/state" \
  "$RUNTIME_IMAGE" /usr/local/bin/stable_node front --state /state/cmux --hostname cmux \
  --control-url http://headscale:8080 --authkey-file /run/cmux-tailnet/authkey \
  --ctl 127.0.0.1:9900 --route 7000=main --place main=backend-a:7000 >/dev/null

# the plain node: an ordinary tailscale node with a TUN, serving the same line echo on 7000
d run -d --name "$PLAIN" --label "$LABEL" --network "$NET" --network-alias plain \
  --cap-add NET_ADMIN --device /dev/net/tun -e TS_DEBUG_USE_DERP_HTTP=1 \
  -v "$WORK/keys/reusable:/run/cmux-tailnet/authkey:ro" \
  -v "$PY_HELPER:/opt/tailnet_bench.py:ro" \
  --entrypoint /bin/sh "$TAILSCALE_IMAGE" -c \
  "apk add -q python3 >/dev/null && tailscaled --state=mem: --socket=/var/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1 &
   sleep 2 && tailscale --socket=/var/run/tailscale/tailscaled.sock up --login-server=http://headscale:8080 \
     --auth-key=file:/run/cmux-tailnet/authkey --hostname=plain && exec python3 -I /opt/tailnet_bench.py serve --port 7000" >/dev/null

# the client: userspace tailscaled with a SOCKS5 server, plus NET_ADMIN for the iptables UDP drops
d run -d --name "$CLIENT" --label "$LABEL" --network "$NET" --hostname client --cap-add NET_ADMIN \
  -e TS_DEBUG_USE_DERP_HTTP=1 \
  -v "$WORK/keys/reusable:/run/cmux-tailnet/authkey:ro" \
  -v "$PY_HELPER:/root/tailnet_bench.py:ro" \
  --entrypoint /bin/sh "$TAILSCALE_IMAGE" -c \
  "apk add -q python3 iptables >/dev/null && exec tailscaled --tun=userspace-networking --state=mem: \
     --socket=/var/run/tailscale/tailscaled.sock --socks5-server=localhost:1055 >/var/log/tailscaled.log 2>&1" >/dev/null
for _ in $(seq 1 120); do d exec "$CLIENT" tailscale --socket=/var/run/tailscale/tailscaled.sock version >/dev/null 2>&1 && break; sleep 1; done
CL_UP_START=$(date +%s%N)
d exec "$CLIENT" tailscale --socket=/var/run/tailscale/tailscaled.sock up --login-server=http://headscale:8080 \
  --auth-key=file:/run/cmux-tailnet/authkey --hostname=client >/dev/null 2>&1 || true
CL_UP_MS=$(( ($(date +%s%N) - CL_UP_START) / 1000000 ))

ts() { d exec "$CLIENT" tailscale --socket=/var/run/tailscale/tailscaled.sock "$@"; }
peer_ip() { # peer_ip HOSTNAME -> its first tailnet IP, once it is in the client's status
  ts status --json 2>/dev/null | jq -r --arg h "$1" '[.Peer[]? | select(.HostName==$h) | .TailscaleIPs[0]][0] // empty'
}
peer_online() { # peer_online HOSTNAME -> "true" when the client sees the peer online
  ts status --json 2>/dev/null | jq -r --arg h "$1" '[.Peer[]? | select(.HostName==$h) | .Online][0] // false'
}
CONNECT_FRONT_MS=""
CONNECT_PLAIN_MS=""
for _ in $(seq 1 480); do
  [[ -z $CONNECT_FRONT_MS && $(peer_online cmux) == true ]] && CONNECT_FRONT_MS=$(( ($(date +%s%N) - FRONT_START) / 1000000 ))
  [[ -z $CONNECT_PLAIN_MS && $(peer_online plain) == true ]] && CONNECT_PLAIN_MS=$(( ($(date +%s%N) - CL_UP_START) / 1000000 ))
  [[ -n $CONNECT_FRONT_MS && -n $CONNECT_PLAIN_MS ]] && break
  sleep 0.25
done
[[ -n $CONNECT_FRONT_MS && -n $CONNECT_PLAIN_MS ]] || { echo "FAIL setup: a peer never came online (front=$CONNECT_FRONT_MS plain=$CONNECT_PLAIN_MS)" >&2; exit 1; }
FRONT_IP=$(peer_ip cmux)
PLAIN_IP=$(peer_ip plain)
log "client up in ${CL_UP_MS} ms; front $FRONT_IP online ${CONNECT_FRONT_MS} ms; plain $PLAIN_IP online ${CONNECT_PLAIN_MS} ms"

# ---------------------------------------------------------------- arms
set_udp() { # set_udp drop|open : all UDP from the client, in and out
  if [[ $1 == drop ]]; then
    d exec "$CLIENT" sh -c 'iptables -F OUTPUT; iptables -F INPUT; iptables -A OUTPUT -p udp -j DROP; iptables -A INPUT -p udp -j DROP'
  else
    d exec "$CLIENT" sh -c 'iptables -F OUTPUT; iptables -F INPUT'
  fi
}
path_of() { # path_of HOSTNAME -> direct | relay | none, from the client's status
  ts status --json 2>/dev/null | jq -r --arg h "$1" '
    [.Peer[]? | select(.HostName==$h)][0] as $p
    | if $p == null then "none" elif ($p.CurAddr // "") != "" then "direct" elif ($p.Relay // "") != "" then "relay" else "none" end'
}
ms_since() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }

run_arm() { # run_arm NAME HOSTNAME IP MODE(open|drop) MOVE(0|1)
  local name=$1 host=$2 ip=$3 mode=$4 move=$5
  local meta=$OUT/$name.meta.json
  set_udp "$mode"
  local want=direct
  [[ $mode == drop ]] && want=relay
  # settle: wait (bounded) until the client's path to the peer is the one this arm measures
  local path=none
  # tailscale only looks for a direct path when traffic or a ping asks; an idle peer stays on relay forever.
  # A direct arm must ask first, or it measures the relay and calls it direct.
  if [[ $want == direct ]]; then
    d exec "$CLIENT" tailscale ping --until-direct --timeout 30s "$ip" >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 120); do
    path=$(path_of "$host")
    [[ $path == "$want" ]] && break
    sleep 0.5
  done
  local settled=$([[ $path == "$want" ]] && echo 1 || echo 0)
  if [[ $settled == 0 ]]; then
    # the arm's path is not the one it names: keep the status for the report, and say so loudly
    ts status --json >"$OUT/$name.unsettled-status.json" 2>/dev/null || true
    log "arm $name: NOT SETTLED (wanted $want, have $path); its rows are not that path's"
  fi
  local load_start
  load_start=$(load1)
  d exec "$CLIENT" rm -f "/root/$name.jsonl"
  : >"$OUT/$name.moves.jsonl"
  local t_start
  t_start=$(date +%s%N)
  d exec -d "$CLIENT" python3 -I /root/tailnet_bench.py client --proto tcp --target "$ip:7000" \
    --duration "$DUR" --out "/root/$name.jsonl" --idle 1.0 --socks 127.0.0.1:1055
  sleep 8
  # T=8: network change, all UDP from the client dropped
  local t_blip
  t_blip=$(date +%s%N)
  set_udp drop
  echo "{\"t_ns\": $t_blip, \"to\": \"blip\"}" >>"$OUT/$name.moves.jsonl"
  sleep 4
  # T=12: restored; time to a direct path (for a derp arm this is the DERP to direct upgrade)
  set_udp open
  local t_restore t_direct_start
  t_restore=$(date +%s%N)
  echo "{\"t_ns\": $t_restore, \"to\": \"restore\"}" >>"$OUT/$name.moves.jsonl"
  t_direct_start=$(date +%s%N)
  local direct_ok=1
  ts ping --until-direct --timeout 40s "$ip" >/dev/null 2>&1 || direct_ok=0
  local time_to_direct_ms
  time_to_direct_ms=$(ms_since "$t_direct_start")
  if [[ $move == 1 ]]; then
    local now_ns
    sleep_until=$(( t_start + 16000000000 ))
    now_ns=$(date +%s%N)
    (( sleep_until > now_ns )) && sleep "$(awk -v a="$sleep_until" -v b="$now_ns" 'BEGIN{printf "%.3f", (a-b)/1e9}')"
    local t_move
    t_move=$(date +%s%N)
    d exec "$FRONT" stable_node ctl 127.0.0.1:9900 \
      '{"kind":"moved","v":1,"workspace":"main","placement":{"ssh":"backend-b:7000"}}' >/dev/null
    echo "{\"t_ns\": $t_move, \"to\": \"B\"}" >>"$OUT/$name.moves.jsonl"
  fi
  # wait for the probe to finish its DUR
  local end_ns=$(( t_start + DUR * 1000000000 + 2000000000 ))
  local now_ns2
  now_ns2=$(date +%s%N)
  (( end_ns > now_ns2 )) && sleep "$(awk -v a="$end_ns" -v b="$now_ns2" 'BEGIN{printf "%.3f", (a-b)/1e9}')"
  d cp "$CLIENT:/root/$name.jsonl" "$OUT/$name.jsonl" >/dev/null 2>&1 || true
  local load_end
  load_end=$(load1)
  jq -n --arg name "$name" --arg host "$host" --arg ip "$ip" --arg mode "$mode" \
    --argjson settled "$settled" --arg path "$path" --argjson direct_ok "$direct_ok" \
    --argjson ttd "$time_to_direct_ms" --arg ls "$load_start" --arg le "$load_end" \
    --argjson move "$move" \
    '{name:$name, host:$host, ip:$ip, udp:$mode, settled:$settled, path_before:$path,
      time_to_direct_ms:$ttd, direct_ok:$direct_ok, move:$move, load1_start:($ls|tonumber), load1_end:($le|tonumber)}' \
    >"$meta"
  log "arm $name: path_before=$path settled=$settled time_to_direct=${time_to_direct_ms}ms load1 $load_start -> $load_end"
}

run_arm plain-direct plain "$PLAIN_IP" open 0
run_arm plain-derp plain "$PLAIN_IP" drop 0
run_arm front-direct cmux "$FRONT_IP" open 1
run_arm front-derp cmux "$FRONT_IP" drop 1

set_udp open
LOAD_END=$(load1)

# ---------------------------------------------------------------- one line: the rows' source
ARMS=()
for n in plain-direct plain-derp front-direct front-derp; do
  ARMS+=("$OUT/$n.meta.json")
done
jq -s '.' "${ARMS[@]}" >"$OUT/arms.json"
python3 -I - "$OUT" "$LOAD_START" "$LOAD_END" "$CL_UP_MS" "$CONNECT_FRONT_MS" "$CONNECT_PLAIN_MS" "$RUN_ID" "$PY_HELPER" <<'PY'
import importlib.util, json, os, sys
out, ls, le, cl_up, cf, cp, run_id, helper_path = sys.argv[1:9]
spec = importlib.util.spec_from_file_location("tb", helper_path)
tb = importlib.util.module_from_spec(spec); spec.loader.exec_module(tb)
arms = json.load(open(os.path.join(out, "arms.json")))
result = {"schema": "tailnet-four-way-run.v1", "run_id": run_id,
          "meta": {"load1_start": float(ls), "load1_end": float(le), "client_up_ms": int(cl_up),
                   "connect_front_ms": int(cf), "connect_plain_ms": int(cp)},
          "arms": []}
for a in arms:
    name = a["name"]
    jl = os.path.join(out, name + ".jsonl")
    mv = os.path.join(out, name + ".moves.jsonl")
    events = tb.load(jl)
    moves = tb.load(mv)
    s = tb.stats(events, moves)
    # the first echo from backend B after the placement move (front arms)
    move_t = [m["t_ns"] for m in moves if m.get("to") == "B"]
    first_b_ms = None
    if move_t:
        rx_b = sorted(e["t"] for e in events if e.get("ev") == "rx" and e.get("who") == "B")
        after = [t for t in rx_b if t >= move_t[0]]
        if after:
            first_b_ms = round((after[0] - move_t[0]) / 1e6, 3)
    a["stats"] = s
    a["first_b_reply_ms"] = first_b_ms
    result["arms"].append(a)
print("TFW-RUN " + json.dumps(result, sort_keys=True))
PY
