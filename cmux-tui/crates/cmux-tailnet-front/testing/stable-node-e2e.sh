#!/usr/bin/env bash
# Live proof of the stable tailnet node on a throwaway tailnet (headscale in docker).
#
# Spins up, on a private docker network labelled with a unique run id:
#   headscale   control server (sqlite, MagicDNS base_domain test.cmux, embedded DERP over HTTP)
#   front       the stable node: `stable_node front` (this crate's example), tsnet hostname `cmux`,
#               state in a labelled docker volume, port 22 -> workspace `main`
#   backend-a   `stable_node echo A`, backend-b `stable_node echo B` (plain docker network, no tailnet)
#   client      a tailscale node (userspace networking) that runs testing/move_probe.py
# and checks:
#   (1) through the tailnet, cmux:22 reaches backend A
#   (2) during a probe, workspace main moves A -> B: the open connection keeps A, new connections
#       land on B; counts dropped connections and measures move -> first B reply and reconnect time
#   (3) the front restarts with the same state: hostname, MagicDNS name and tailnet IP unchanged,
#       and headscale still lists exactly one `cmux` node
#
# It never touches the host's tailscaled or network: tsnet and every tailscaled run inside
# containers. Cleanup removes only the containers, network and volume carrying this run's label.
#
# Usage: stable-node-e2e.sh STABLE_NODE_BINARY   (built with
#   cargo build -p cmux-tailnet-front --features tsnet --example stable_node; a glibc binary,
#   run in $RUNTIME_IMAGE, default ubuntu:24.04)
# env: KEEP=1, PROBE_S (default 8), MOVE_AT_S (default 3), INTERVAL_S (default 0.05)
#
# ACPMUX_BINARY=PATH runs the front inside acpmux instead (an `acpmux` built with
# `--features tailnet`): `acpmux daemon run` in the front container (hostname `cmux`), its
# embedded node joined through CMUX_TAILNET_CONTROL_URL / CMUX_TAILNET_AUTHKEY_FILE, the
# `tailnet.stableNode.enabled` setting on, and every placement sent with
# `acpmux daemon placement JSON` (the `_acpmux/tailnet/placement` request). The identity checks
# read the node from headscale. STABLE_NODE_BINARY still runs the two echo backends.
set -euo pipefail

BIN=${1:?usage: stable-node-e2e.sh STABLE_NODE_BINARY}
BIN=$(readlink -f "$BIN")
HERE=$(cd "$(dirname "$0")" && pwd)
HEADSCALE_IMAGE=${HEADSCALE_IMAGE:-headscale/headscale:0.27.1}
TAILSCALE_IMAGE=${TAILSCALE_IMAGE:-tailscale/tailscale:stable}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-ubuntu:24.04}
PROBE_S=${PROBE_S:-8}
MOVE_AT_S=${MOVE_AT_S:-3}
INTERVAL_S=${INTERVAL_S:-0.05}
RUN_ID="cmux-stable-node-e2e-$(date +%s)-$$-$RANDOM"
LABEL="cmux.stable-node-e2e.run=$RUN_ID"
NET="$RUN_ID"
HS="$RUN_ID-headscale"
FRONT="$RUN_ID-front"
BA="$RUN_ID-backend-a"
BB="$RUN_ID-backend-b"
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmux-stable-node-e2e.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/keys"

FAILS=0
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
result() { # result PASS|FAIL name detail
  printf '%s %s%s\n' "$1" "$2" "${3:+ - $3}"
  [[ $1 == PASS ]] || FAILS=$((FAILS + 1))
}

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

# ---------------------------------------------------------------- headscale
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
{
  "acls": [{ "action": "accept", "src": ["*"], "dst": ["*:*"] }],
  "ssh": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["autogroup:self"],
      "users": ["root", "autogroup:nonroot"]
    }
  ]
}
EOF

log "run $RUN_ID: images $HEADSCALE_IMAGE, $TAILSCALE_IMAGE, $RUNTIME_IMAGE"
d network create --label "$LABEL" "$NET" >/dev/null
d volume create --label "$LABEL" "$VOL" >/dev/null
d create --name "$HS" --label "$LABEL" --network "$NET" --network-alias headscale \
  "$HEADSCALE_IMAGE" serve >/dev/null
mkdir -p "$WORK/etc-headscale"
cp "$WORK/config.yaml" "$WORK/policy.json" "$WORK/etc-headscale/"
d cp "$WORK/etc-headscale/." "$HS:/etc/headscale/"
d start "$HS" >/dev/null
hs() { d exec "$HS" headscale "$@"; }
for _ in $(seq 1 60); do
  hs users list >/dev/null 2>&1 && break
  sleep 0.5
done
hs users list >/dev/null 2>&1 || { d logs "$HS" 2>&1 | tail -30; result FAIL setup "headscale did not come up"; exit 1; }
hs users create cmux >/dev/null
USER_ID=$(hs users list -o json | jq -r '.[] | select(.name=="cmux") | .id')
( umask 077
  hs preauthkeys create --user "$USER_ID" --reusable --expiration 1h -o json | jq -r .key >"$WORK/keys/reusable" )
[[ -s $WORK/keys/reusable ]] || { result FAIL setup "could not mint a pre-auth key"; exit 1; }
chmod 644 "$WORK/keys/reusable" # read by root in containers; the dir stays 0700
log "headscale up; user cmux id=$USER_ID"

# ---------------------------------------------------------------- backends, front, client
run_bin() { # run_bin NAME ALIAS ARGS...
  local name=$1 alias=$2; shift 2
  d run -d --name "$name" --label "$LABEL" --network "$NET" --network-alias "$alias" \
    -e TS_DEBUG_USE_DERP_HTTP=1 \
    -v "$BIN:/usr/local/bin/stable_node:ro" \
    -v "$WORK/keys/reusable:/run/cmux-tailnet/authkey:ro" \
    -v "$VOL:/state" \
    "$RUNTIME_IMAGE" /usr/local/bin/stable_node "$@" >/dev/null
}
run_bin "$BA" backend-a echo A 0.0.0.0:7000
run_bin "$BB" backend-b echo B 0.0.0.0:7000
ACPMUX=${ACPMUX_BINARY:+$(readlink -f "$ACPMUX_BINARY")}
WS=main
[[ -n $ACPMUX ]] && WS=default
place() { # place JSON -> the front's answer, as {"ok":true,"t":...} in both modes
  if [[ -n $ACPMUX ]]; then
    local out
    out=$(d exec -e ACPMUX_HOME=/state/home "$FRONT" acpmux daemon placement "$1" 2>&1) \
      || { jq -nc --arg e "$out" '{ok:false,error:$e}'; return; }
    jq -c --argjson t "$(date +%s.%N)" '{ok: (.result == "placed" or .result == "removed"), t: $t, reply: .}' <<<"$out"
  else
    d exec "$FRONT" stable_node ctl 127.0.0.1:9900 "$1"
  fi
}
start_front() {
  if [[ -n $ACPMUX ]]; then
    # The opt-in marker a person's Start leaves, so the daemon starts its node on launch.
    d run --rm --label "$LABEL" -v "$VOL:/state" "$RUNTIME_IMAGE" sh -c \
      'umask 077; mkdir -p /state/home/tailnet && [ -f /state/home/tailnet/enabled ] || echo 1 >/state/home/tailnet/enabled'
    printf '{"tailnet.stableNode.enabled": true}\n' >"$WORK/cmux-next.json"
    chmod 644 "$WORK/cmux-next.json"
    d run -d --name "$FRONT" --label "$LABEL" --network "$NET" --network-alias front \
      --hostname cmux \
      -e TS_DEBUG_USE_DERP_HTTP=1 -e ACPMUX_HOME=/state/home -e HOME=/state/user \
      -e CMUX_NEXT_CONFIG_FILE=/etc/cmux-next.json \
      -e CMUX_TAILNET_CONTROL_URL=http://headscale:8080 \
      -e CMUX_TAILNET_AUTHKEY_FILE=/run/cmux-tailnet/authkey \
      -v "$ACPMUX:/usr/local/bin/acpmux:ro" \
      -v "$WORK/cmux-next.json:/etc/cmux-next.json:ro" \
      -v "$WORK/keys/reusable:/run/cmux-tailnet/authkey:ro" \
      -v "$VOL:/state" \
      "$RUNTIME_IMAGE" /usr/local/bin/acpmux daemon run --log info >/dev/null
  else
    run_bin "$FRONT" front front --state /state/cmux --hostname cmux \
      --control-url http://headscale:8080 --authkey-file /run/cmux-tailnet/authkey \
      --ctl 127.0.0.1:9900 --route 22=main --place main=backend-a:7000
  fi
}
front_log() { # the acpmux daemon's output and its log file
  d logs "$FRONT" 2>&1 || true
  d exec "$FRONT" cat /state/home/daemon.log 2>/dev/null || true
}
serving_count() { front_log | grep -c 'tailnet front: serving' || true; }
hs_identity() { # the cmux node as headscale lists it, once it is online
  hs nodes list -o json 2>/dev/null | jq -c '[.[]? | select(.given_name == "cmux" and (.online // false))][0]
    | select(. != null) | {hostname: .given_name, dns_name: (.given_name + ".test.cmux."), ips: .ip_addresses}'
}
identity() { # identity -> the front's identity JSON line, once it printed one
  if [[ -n $ACPMUX ]]; then
    for _ in $(seq 1 360); do
      local line
      line=$(hs_identity || true)
      [[ -n $line ]] && { echo "$line"; return 0; }
      sleep 0.25
    done
    return 1
  fi
  for _ in $(seq 1 360); do
    local line
    line=$(d logs "$FRONT" 2>/dev/null | grep '"event":"identity"' | tail -1 || true)
    [[ -n $line ]] && { echo "$line"; return 0; }
    sleep 0.25
  done
  return 1
}
T0=$(date +%s.%N)
start_front
if ID1=$(identity); then
  result PASS front-up "stable node Running $(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}')s after start: $ID1"
else
  d logs "$FRONT" 2>&1 | sed 's/tskey-[A-Za-z0-9-]*/tskey-REDACTED/g; s/hskey-[A-Za-z0-9_-]*/hskey-REDACTED/g' | tail -30
  log "headscale nodes: $(hs nodes list -o json 2>/dev/null | jq -c '[.[]? | {given_name, name, online}]' || true)"
  front_log 2>&1 | grep -iE 'tailnet|tsnet|control' | tail -20 || true
  result FAIL front-up "stable node never Running"; exit 1
fi
if [[ -n $ACPMUX ]]; then
  for _ in $(seq 1 80); do
    [[ $(serving_count) -gt 0 ]] && break
    sleep 0.25
  done
  front_log | grep 'tailnet front' | sed 's/^/    /' | tail -3
  SET=$(place '{"kind":"set","v":1,"workspace":"default","placement":{"ssh":"backend-a:7000"}}')
  log "placement set default -> backend-a: $SET"
else
  for _ in $(seq 1 80); do
    d logs "$FRONT" 2>/dev/null | grep -q '"event":"serving"' && break
    sleep 0.25
  done
fi

d run -d --name "$CLIENT" --label "$LABEL" --network "$NET" --hostname client \
  -e TS_DEBUG_USE_DERP_HTTP=1 \
  -v "$WORK/keys/reusable:/run/cmux-tailnet/authkey:ro" \
  --entrypoint /bin/sh "$TAILSCALE_IMAGE" -c \
  "exec tailscaled --tun=userspace-networking --state=mem: \
     --socket=/var/run/tailscale/tailscaled.sock \
     --socks5-server=localhost:1055 >/var/log/tailscaled.log 2>&1" >/dev/null
d exec "$CLIENT" apk add -q python3 >/dev/null
d cp "$HERE/move_probe.py" "$CLIENT:/root/move_probe.py"
d exec "$CLIENT" tailscale up --login-server=http://headscale:8080 \
  --auth-key=file:/run/cmux-tailnet/authkey --hostname=cmux-client-test >/dev/null 2>&1 || true
for _ in $(seq 1 240); do
  d exec "$CLIENT" tailscale status --json 2>/dev/null \
    | jq -e '.BackendState=="Running" and ([.Peer[]? | select(.DNSName|startswith("cmux."))] | length > 0)' >/dev/null 2>&1 && break
  sleep 0.25
done
PEER=$(d exec "$CLIENT" tailscale status --json | jq -c '[.Peer[]? | select(.DNSName|startswith("cmux."))][0] | {DNSName, TailscaleIPs}')
log "client sees the stable node: $PEER"

# ---------------------------------------------------------------- (1) reach A
REACH=$(d exec "$CLIENT" python3 /root/move_probe.py cmux.test.cmux 22 0.5 0.1 2>&1 || true)
FIRST=$(jq -r .first <<<"$REACH" 2>/dev/null || true)
if [[ $FIRST == A ]]; then
  result PASS reach "cmux.test.cmux:22 through the tailnet -> backend A"
else
  echo "    $REACH" | tail -5
  result FAIL reach "cmux:22 did not reach backend A"
fi

# ---------------------------------------------------------------- (2) move under load
log "probe ${PROBE_S}s at ${INTERVAL_S}s spacing; move main A -> B at ${MOVE_AT_S}s"
d exec "$CLIENT" python3 /root/move_probe.py cmux.test.cmux 22 "$PROBE_S" "$INTERVAL_S" >"$WORK/probe.json" 2>"$WORK/probe.err" &
PROBE_PID=$!
sleep "$MOVE_AT_S"
T_ASK=$(date +%s.%N)
MOVE=$(place "{\"kind\":\"moved\",\"v\":1,\"workspace\":\"$WS\",\"placement\":{\"ssh\":\"backend-b:7000\"}}")
log "move answered in $(awk -v a="$T_ASK" -v b="$(jq -r .t <<<"$MOVE")" 'BEGIN{printf "%.1f", (b-a)*1000}') ms: $MOVE"
wait "$PROBE_PID" || true
T_MOVE=$(jq -r .t <<<"$MOVE")
if [[ $(jq -r .ok <<<"$MOVE") != true || ! -s $WORK/probe.json ]]; then
  echo "    move: $MOVE"; tail -5 "$WORK/probe.err"
  result FAIL move "move or probe failed"
else
  jq --argjson tm "$T_MOVE" -r '
    def pct(p): sort | if length == 0 then null else .[((length - 1) * p | floor)] end;
    def r2: if . == null then "n/a" else (. * 100 | round / 100 | tostring) end;
    .samples as $s
    | ($s.long | map(select(.error)) | length) as $long_err
    | ($s.long | map(select(.backend and .backend != "A")) | length) as $long_not_a
    | ($s.long | length) as $long_n
    | ($s.new | map(select(.error)) | length) as $new_err
    | ($s.new | length) as $new_n
    | ($s.new | map(select(.t > $tm and .backend == "B"))) as $after_b
    | ($s.new | map(select(.t > $tm and .backend == "A")) | length) as $after_a
    | ($after_b | map(.t + .ms / 1000) | min) as $first_b_done
    | ($s.new | map(select(.t < $tm and .backend)) | map(.ms)) as $before_ms
    | ($after_b | map(.ms)) as $after_ms
    | "long_n=\($long_n) long_errors=\($long_err) long_not_A=\($long_not_a)",
      "new_n=\($new_n) new_errors=\($new_err) new_after_move_on_A=\($after_a) new_after_move_on_B=\($after_b | length)",
      "move_to_first_B_reply_ms=\(if $first_b_done then (($first_b_done - $tm) * 1000 | r2) else "n/a" end)",
      "new_conn_ms_before p50=\($before_ms | pct(0.5) | r2) p95=\($before_ms | pct(0.95) | r2) max=\($before_ms | max | r2)",
      "new_conn_ms_after p50=\($after_ms | pct(0.5) | r2) p95=\($after_ms | pct(0.95) | r2) max=\($after_ms | max | r2)",
      "long_ask_ms p50=\($s.long | map(.ms) | pct(0.5) | r2) p95=\($s.long | map(.ms) | pct(0.95) | r2)",
      "reconnect_after_close backend=\(.reconnect.backend // .reconnect.error) ms=\(.reconnect.ms // null | r2)",
      "first=\(.first)"' "$WORK/probe.json" | tee "$WORK/numbers.txt" | sed 's/^/    /'
  N=$(cat "$WORK/numbers.txt")
  if grep -q 'long_errors=0 long_not_A=0' <<<"$N" && grep -q 'new_errors=0' <<<"$N" \
     && grep -q 'new_after_move_on_A=0' <<<"$N" && grep -q 'reconnect_after_close backend=B' <<<"$N" \
     && ! grep -q 'new_after_move_on_B=0$' <<<"$N"; then
    result PASS move "open connection kept A, every new connection after the move landed on B, none dropped"
  else
    result FAIL move "see numbers above"
  fi
fi

# ---------------------------------------------------------------- (3) restart keeps identity
SERVED_BEFORE=0
[[ -n $ACPMUX ]] && SERVED_BEFORE=$(serving_count)
d restart -t 5 "$FRONT" >/dev/null
T0=$(date +%s.%N)
sleep 0.5
ID2=""
if [[ -n $ACPMUX ]]; then
  # Offline first (headscale notices the old session end), then online again.
  sleep 1
  # The daemon keeps placements in memory: the app sends them again when the daemon starts.
  for _ in $(seq 1 360); do
    ID2=$(hs_identity || true)
    [[ -n $ID2 && $(serving_count) -gt $SERVED_BEFORE ]] && break
    ID2=""
    sleep 0.25
  done
  RESEND=$(place '{"kind":"set","v":1,"workspace":"default","placement":{"ssh":"backend-a:7000"}}')
  log "placement sent again after the restart: $RESEND"
fi
for _ in $(seq 1 360); do
  [[ -n $ACPMUX ]] && break
  ID2=$(d logs --since "$(date -u -d "@${T0%.*}" +%Y-%m-%dT%H:%M:%SZ)" "$FRONT" 2>/dev/null | grep '"event":"identity"' | tail -1 || true)
  [[ -n $ID2 ]] && break
  sleep 0.25
done
RESTART_S=$(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}')
same() { jq -c '{hostname, dns_name, ips}' <<<"$1"; }
CMUX_NODES=$(hs nodes list -o json | jq '[.[]? | select(.given_name | startswith("cmux") and (startswith("cmux-client") | not))] | length')
for _ in $(seq 1 80); do
  [[ -n $ACPMUX ]] && break
  d logs "$FRONT" 2>/dev/null | grep -c '"event":"serving"' | grep -q '^2$' && break
  sleep 0.25
done
AGAIN=$(d exec "$CLIENT" python3 /root/move_probe.py cmux.test.cmux 22 0.3 0.1 2>&1 || true)
if [[ -n $ID2 && $(same "$ID1") == "$(same "$ID2")" && $CMUX_NODES == 1 && $(jq -r .first <<<"$AGAIN" 2>/dev/null) == A ]]; then
  result PASS restart "identity unchanged across restart ($(same "$ID2")); Running again ${RESTART_S}s after restart; headscale lists 1 cmux node; cmux:22 answers again"
else
  printf '    before: %s\n    after:  %s\n    cmux nodes: %s\n    again: %s\n' "$(same "$ID1")" "$(same "${ID2:-{\}}")" "$CMUX_NODES" "$AGAIN"
  result FAIL restart "identity changed or node not back"
fi
log "headscale nodes:"
hs nodes list -o json | jq -r '.[]? | "    id=\(.id) \(.given_name) \(.ip_addresses | join(",")) online=\(.online // false)"'

[[ $FAILS == 0 ]] && log "all checks passed" || log "$FAILS check(s) failed"
exit "$FAILS"
