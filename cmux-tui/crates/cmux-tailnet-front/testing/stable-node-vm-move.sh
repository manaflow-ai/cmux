#!/usr/bin/env bash
# The stable tailnet node's move with real Cloud VMs as backends (stable-node-e2e.sh's ACPMUX mode,
# with backend-a and backend-b on two staging machines instead of two containers).
#
# On a throwaway tailnet nobody else is on:
#   headscale   in docker on this runner (sqlite, MagicDNS test.cmux), its control port reached from
#               the VMs through a bore.pub TCP tunnel (raw TCP, so Tailscale's control upgrade passes;
#               the control protocol is Noise-encrypted end to end, so the relay sees no keys).
#               No embedded DERP: bore carries TCP only, so the nodes use Tailscale's public DERP map.
#   backends    two staging VMs (scripts/cmux-next/tailnet-move-vms.ts up), each a userspace tailscaled
#               joined as backend-a / backend-b and an echo on :7000 answering "A:" / "B:"
#   uplink      a kernel-mode tailscaled container (hostname cmux): the front dials backends with plain
#               TCP, so it shares this container's network and its route to the VMs' tailnet IPs
#   front       `acpmux daemon run` (built with --features tailnet) in the uplink's network, its embedded
#               node `cmux`, placement default -> backend-a's tailnet IP:7000
#   client      a userspace tailscaled container that runs move_probe.py against cmux.test.cmux:22
# Checks, with stable-node-e2e.sh's rows: reach (cmux:22 -> A), move A -> B under move_probe.py load,
# restart keeps the identity.
#
# Every node joins with its own single-use pre-auth key (1 h; ephemeral except the front, whose identity
# must survive its restart), files 0600 in a 0700 dir, masked in Actions logs. Cleanup removes only this
# run's labelled containers, network and volume, deletes every node from headscale, and runs
# `tailnet-move-vms.ts down` (logout, delete both VMs). It never touches the host's tailscaled.
#
# Usage: stable-node-vm-move.sh ACPMUX_BINARY [CMUX_BINARY]
# env: CMUX_DOGFOOD_STACK_EMAIL, CMUX_DOGFOOD_STACK_PASSWORD, PRODUCT_TEAM (tailnet-move-vms.ts);
#      RUN (machine name part, default GITHUB_RUN_ID-GITHUB_RUN_ATTEMPT); OUT (rows file);
#      PROBE_S (default 20), MOVE_AT_S (default 8), INTERVAL_S (default 0.1); KEEP=1
set -euo pipefail

ACPMUX=$(readlink -f "${1:?usage: stable-node-vm-move.sh ACPMUX_BINARY [CMUX_BINARY]}")
# The cmux CLI (cmux-tui) mints VM B's key (`cmux vm tailnet mint-key --headscale-api`): the Mac's
# path, where only a single-use key ever reaches a VM and the admin credential stays home.
CMUX_CLI=${2:+$(readlink -f "$2")}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../.." && pwd)
HEADSCALE_IMAGE=${HEADSCALE_IMAGE:-headscale/headscale:0.27.1}
TAILSCALE_IMAGE=${TAILSCALE_IMAGE:-tailscale/tailscale:stable}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-ubuntu:24.04}
BORE_URL=https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-unknown-linux-musl.tar.gz
BORE_SHA256=e484d1e3acba77169b773f31a5bfb34192d4b660f44a094a658a2522cd2270f7
PROBE_S=${PROBE_S:-20}
MOVE_AT_S=${MOVE_AT_S:-8}
INTERVAL_S=${INTERVAL_S:-0.1}
RUN=${RUN:-${GITHUB_RUN_ID:-local$(date +%s)}-${GITHUB_RUN_ATTEMPT:-1}}
RUN_ID="cmux-stable-node-vm-move-$(date +%s)-$$-$RANDOM"
LABEL="cmux.stable-node-vm-move.run=$RUN_ID"
NET="$RUN_ID"
HS="$RUN_ID-headscale"
UPLINK="$RUN_ID-uplink"
FRONT="$RUN_ID-front"
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

# Pull every image up front, retrying: a shared runner's containerd can drop a
# pull mid-extract ("lease does not exist"), which is no fault of the move.
pull_image() {
  local image=$1 try
  d image inspect "$image" >/dev/null 2>&1 && return 0
  for try in 1 2 3 4; do
    d pull -q "$image" >/dev/null 2>&1 && return 0
    echo "pull $image failed (try $try of 4); retrying" >&2
    sleep $((try * 5))
  done
  echo "FAIL setup: could not pull $image after 4 tries" >&2
  return 1
}
for image in "$HEADSCALE_IMAGE" "$TAILSCALE_IMAGE" "$RUNTIME_IMAGE"; do
  pull_image "$image" || exit 2
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmux-stable-node-vm-move.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/keys"
OUT=${OUT:-$WORK/rows.txt}
: >"$OUT"

FAILS=0
BORE_PID=""
VMS_UP=0
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
row() { printf '%s\n' "$*" | tee -a "$OUT"; }
result() { # result PASS|FAIL name detail
  row "$1 $2${3:+ - $3}"
  [[ $1 == PASS ]] || FAILS=$((FAILS + 1))
}
redact() { sed -E 's/(tskey|hskey)-[A-Za-z0-9_-]+/\1-REDACTED/g'; }

cleanup() {
  local rc=$?
  if [[ ${KEEP:-0} == 1 ]]; then
    log "KEEP=1: leaving run $RUN_ID (label $LABEL), work dir $WORK, VMs of run $RUN"
    return
  fi
  if [[ -n $(d ps -q --filter "name=^$HS\$" 2>/dev/null) ]]; then
    # Every node off the throwaway tailnet before the control server goes.
    for id in $(d exec "$HS" headscale nodes list -o json 2>/dev/null | jq -r '.[]?.id' || true); do
      d exec "$HS" headscale nodes delete --identifier "$id" --force >/dev/null 2>&1 || true
    done
  fi
  if [[ $VMS_UP == 1 ]]; then
    (cd "$REPO" && bun scripts/cmux-next/tailnet-move-vms.ts down --run "$RUN") 2>&1 | redact || true
  fi
  local ids
  ids=$(d ps -aq --filter "label=$LABEL" 2>/dev/null || true)
  [[ -n $ids ]] && d rm -fv $ids >/dev/null 2>&1 || true
  ids=$(d network ls -q --filter "label=$LABEL" 2>/dev/null || true)
  [[ -n $ids ]] && d network rm $ids >/dev/null 2>&1 || true
  ids=$(d volume ls -q --filter "label=$LABEL" 2>/dev/null || true)
  [[ -n $ids ]] && d volume rm $ids >/dev/null 2>&1 || true
  [[ -n $BORE_PID ]] && kill $BORE_PID 2>/dev/null || true
  [[ $OUT == "$WORK"/* ]] && cat "$OUT"
  rm -rf -- "$WORK"
  log "cleaned up run $RUN_ID"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- the control port, reachable from the VMs
mkdir -m 700 "$WORK/bore"
curl -fsSL --retry 5 -o "$WORK/bore/bore.tgz" "$BORE_URL"
echo "$BORE_SHA256  $WORK/bore/bore.tgz" | sha256sum -c --quiet -
tar -xzf "$WORK/bore/bore.tgz" -C "$WORK/bore" bore
"$WORK/bore/bore" local 8080 --to bore.pub >"$WORK/bore/log" 2>&1 &
BORE_PID=$!
PORT=""
for _ in $(seq 1 60); do
  PORT=$(grep -oE 'listening at bore\.pub:[0-9]+' "$WORK/bore/log" | grep -oE '[0-9]+$' | head -1 || true)
  [[ -n $PORT ]] && break
  sleep 0.5
done
[[ -n $PORT ]] || { cat "$WORK/bore/log"; result FAIL setup "bore.pub gave no port"; exit 1; }
CONTROL="http://bore.pub:$PORT"
log "control URL $CONTROL (bore.pub TCP relay to this runner's 127.0.0.1:8080)"
# Run 45621004035: the relay answered /health at 13:20 and refused the VMs' joins at 13:25 ("connection
# refused" on bore.pub:$PORT), so the client's session had dropped. Keep it up: reconnect at once, asking for
# the same port, and log each drop so a refusal in a later step names its cause.
BORE_FIRST=$BORE_PID
(
  trap 'kill "$child" 2>/dev/null; exit 0' TERM
  child=$BORE_FIRST
  while :; do
    wait "$child" 2>/dev/null || true
    kill -0 "$child" 2>/dev/null && { sleep 2; continue; }
    echo "[$(date +%H:%M:%S)] bore session to bore.pub:$PORT dropped; reconnecting on the same port" >>"$WORK/bore/drops"
    "$WORK/bore/bore" local 8080 --to bore.pub --port "$PORT" >>"$WORK/bore/log" 2>&1 &
    child=$!
    sleep 1
  done
) &
BORE_PID="$! $BORE_FIRST"
control_up() { # control_up WHY: the relay still reaches headscale, else FAIL with its drop log
  local _
  for _ in $(seq 1 30); do curl -fsS -m 5 "$CONTROL/health" >/dev/null 2>&1 && return 0; sleep 1; done
  cat "$WORK/bore/drops" "$WORK/bore/log" 2>/dev/null | tail -20
  result FAIL setup "headscale not reachable through $CONTROL $1"; exit 1
}

# ---------------------------------------------------------------- headscale
cat >"$WORK/config.yaml" <<EOF
server_url: $CONTROL
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
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default
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

log "run $RUN_ID (VMs: run $RUN): images $HEADSCALE_IMAGE, $TAILSCALE_IMAGE, $RUNTIME_IMAGE"
d network create --label "$LABEL" "$NET" >/dev/null
d volume create --label "$LABEL" "$VOL" >/dev/null
d create --name "$HS" --label "$LABEL" --network "$NET" -p 127.0.0.1:8080:8080 \
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
for _ in $(seq 1 40); do
  curl -fsS -m 5 "$CONTROL/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS -m 5 "$CONTROL/health" >/dev/null || { cat "$WORK/bore/log"; result FAIL setup "headscale not reachable through $CONTROL"; exit 1; }
hs users create cmux >/dev/null
# This runner's docker daemon does not see the job's files (a bind mount of a key file arrived as an empty
# directory: "read /run/cmux-tailnet/authkey: is a directory", run 45594358383), so every file goes in with
# `docker cp` into a created container before it starts: KEY (0600, dir 0700) to /run/cmux-tailnet/authkey.
put_key() { # put_key CONTAINER NAME
  local dir="$WORK/keydir-$2"
  mkdir -m 700 "$dir" && install -m 600 "$WORK/keys/$2" "$dir/authkey"
  d cp "$dir/." "$1:/run/cmux-tailnet/"
  rm -rf "$dir"
}
USER_ID=$(hs users list -o json | jq -r '.[] | select(.name=="cmux") | .id')
mint() { # mint NAME [--ephemeral]: one single-use key, 1 h, in keys/NAME (0600), masked
  local name=$1; shift
  ( umask 077
    hs preauthkeys create --user "$USER_ID" --expiration 1h "$@" -o json | jq -r .key >"$WORK/keys/$name" )
  [[ -s $WORK/keys/$name ]] || { result FAIL setup "could not mint the $name key"; exit 1; }
  [[ -n ${GITHUB_ACTIONS:-} ]] && echo "::add-mask::$(cat "$WORK/keys/$name")"
  return 0
}
for n in a uplink client; do mint "$n" --ephemeral; done
mint front
# VM B's key comes from cmux itself: a throwaway headscale API key goes to `cmux vm tailnet mint-key`
# on stdin, which asks headscale's API for one single-use ephemeral key (10 min) and writes it 0600.
MINTED_BY_CMUX=""
if [[ -n $CMUX_CLI ]]; then
  APIKEY=$(hs apikeys create --expiration 1h 2>/dev/null | tail -1)
  [[ -n ${GITHUB_ACTIONS:-} && -n $APIKEY ]] && echo "::add-mask::$APIKEY"
  if (umask 077; printf '%s' "$APIKEY" | "$CMUX_CLI" --json vm tailnet mint-key --key-stdin --headscale-api \
        --login-server http://127.0.0.1:8080 --allow-http --headscale-user "$USER_ID" --ephemeral \
        --out "$WORK/keys/b" >"$WORK/mint.json" 2>"$WORK/mint.err") && [[ -s $WORK/keys/b ]]; then
    [[ -n ${GITHUB_ACTIONS:-} ]] && echo "::add-mask::$(cat "$WORK/keys/b")"
    MODE=$(stat -c %a "$WORK/keys/b")
    MINTED_BY_CMUX=$(cat "$WORK/keys/b")
    result PASS mint "cmux vm tailnet mint-key wrote VM B's key ($MODE, $(jq -c '{reusable,ephemeral,expiresInSecs}' "$WORK/mint.json")) from a headscale API key; the API key stays on the runner"
  else
    redact <"$WORK/mint.err"
    result FAIL mint "cmux vm tailnet mint-key did not mint VM B's key"; exit 1
  fi
  unset APIKEY
else
  mint b --ephemeral
fi
log "headscale up behind $CONTROL; user cmux id=$USER_ID; 5 single-use keys (front not ephemeral)"

# ---------------------------------------------------------------- backends: two staging VMs
TARBALL=$(curl -fsS --retry 3 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.Tarballs.amd64')
[[ $TARBALL == tailscale_*_amd64.tgz ]] || { result FAIL setup "no tailscale tarball name ($TARBALL)"; exit 1; }
control_up "before the VMs join"
VMS_UP=1
T0=$(date +%s.%N)
if (cd "$REPO" && bun scripts/cmux-next/tailnet-move-vms.ts up --run "$RUN" --login-server "$CONTROL" \
      --key-a "$WORK/keys/a" --key-b "$WORK/keys/b" --tarball "https://pkgs.tailscale.com/stable/$TARBALL" \
      --json "$WORK/vms.json") 2>&1 | redact; then :; fi
if [[ ! -s $WORK/vms.json ]]; then
  cat "$WORK/bore/drops" 2>/dev/null || true
  result FAIL vms "two staging VMs did not come up on the tailnet"; exit 1
fi
IP_A=$(jq -r .a.ip "$WORK/vms.json")
IP_B=$(jq -r .b.ip "$WORK/vms.json")
if [[ -n $MINTED_BY_CMUX ]]; then
  # The one key cmux minted is spent: headscale lists it used, single-use, and B is on the tailnet. (It is
  # the newest key: headscale versions that list only a key's prefix still find it.) Headscale's JSON is
  # protobuf's, which leaves a false bool out, so a missing reusable or ephemeral reads as false.
  KEYROW=$(hs preauthkeys list --user "$USER_ID" -o json 2>/dev/null | jq -c --arg k "$MINTED_BY_CMUX" \
    '(map(select(.key == $k)) + [max_by(.id | tostring | tonumber)])[0]
     | {id, used: (.used // false), reusable: (.reusable // false), ephemeral: (.ephemeral // false)}')
  if [[ $(jq -r '.used == true and .reusable == false and .ephemeral == true' <<<"$KEYROW") == true ]]; then
    result PASS mint-used "VM B joined with the cmux-minted key; headscale lists it $KEYROW"
  else
    result FAIL mint-used "headscale lists the cmux-minted key as ${KEYROW:-missing}"
  fi
  unset MINTED_BY_CMUX
fi
result PASS vms "staging machines $(jq -r '.a.machine + " (A " + .a.ip + ") and " + .b.machine + " (B " + .b.ip + ")"' "$WORK/vms.json") joined in $(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.0f", b-a}')s"

# ---------------------------------------------------------------- uplink: the front's route to the VMs
d create --name "$UPLINK" --label "$LABEL" --network "$NET" --hostname cmux \
  --cap-add NET_ADMIN --cap-add NET_RAW --device /dev/net/tun \
  --entrypoint /bin/sh "$TAILSCALE_IMAGE" -c \
  "exec tailscaled --state=mem: --socket=/var/run/tailscale/tailscaled.sock >/var/log/tailscaled.log 2>&1" >/dev/null
put_key "$UPLINK" uplink
d start "$UPLINK" >/dev/null
for _ in $(seq 1 40); do d exec "$UPLINK" test -S /var/run/tailscale/tailscaled.sock && break; sleep 0.25; done
if ! d exec "$UPLINK" tailscale up --login-server="$CONTROL" --auth-key=file:/run/cmux-tailnet/authkey \
  --hostname=cmux-uplink --accept-dns=false --timeout=120s 2>&1 | redact; then
  d exec "$UPLINK" tail -20 /var/log/tailscaled.log 2>&1 | redact
  result FAIL uplink "tailscale up failed in the uplink container"; exit 1
fi
UPA=""
for _ in $(seq 1 120); do
  UPA=$(d exec "$UPLINK" sh -c "printf hi | nc -w 3 $IP_A 7000" 2>/dev/null || true)
  [[ $UPA == A:hi ]] && break
  sleep 0.5
done
if [[ $UPA == A:hi ]]; then
  result PASS uplink "the front's network reaches backend A at $IP_A:7000 over the tailnet"
else
  d exec "$UPLINK" tailscale status 2>&1 | tail -10 || true
  d exec "$UPLINK" tail -20 /var/log/tailscaled.log 2>&1 | redact || true
  result FAIL uplink "no answer from $IP_A:7000 ($UPA)"; exit 1
fi

# ---------------------------------------------------------------- front: acpmux in the uplink's network
place() { # place JSON -> {"ok":true,"t":...}
  local out
  out=$(d exec -e ACPMUX_HOME=/state/home "$FRONT" acpmux daemon placement "$1" 2>&1) \
    || { jq -nc --arg e "$out" '{ok:false,error:$e}'; return; }
  jq -c --argjson t "$(date +%s.%N)" '{ok: (.result == "placed" or .result == "removed"), t: $t, reply: .}' <<<"$out"
}
d run --rm --label "$LABEL" -v "$VOL:/state" "$RUNTIME_IMAGE" sh -c \
  'umask 077; mkdir -p /state/home/tailnet && [ -f /state/home/tailnet/enabled ] || echo 1 >/state/home/tailnet/enabled'
printf '{"tailnet.stableNode.enabled": true}\n' >"$WORK/cmux-next.json"
chmod 644 "$WORK/cmux-next.json"
T0=$(date +%s.%N)
d create --name "$FRONT" --label "$LABEL" --network "container:$UPLINK" \
  -e ACPMUX_HOME=/state/home -e HOME=/state/user \
  -e CMUX_NEXT_CONFIG_FILE=/etc/cmux-next.json \
  -e CMUX_TAILNET_CONTROL_URL="$CONTROL" \
  -e CMUX_TAILNET_AUTHKEY_FILE=/run/cmux-tailnet/authkey \
  -v "$VOL:/state" \
  "$RUNTIME_IMAGE" /usr/local/bin/acpmux daemon run --log info >/dev/null
d cp "$ACPMUX" "$FRONT:/usr/local/bin/acpmux"
d cp "$WORK/cmux-next.json" "$FRONT:/etc/cmux-next.json"
put_key "$FRONT" front
d start "$FRONT" >/dev/null
front_log() {
  d logs "$FRONT" 2>&1 || true
  d exec "$FRONT" cat /state/home/daemon.log 2>/dev/null || true
}
serving_count() { front_log | grep -c 'tailnet front: serving' || true; }
hs_identity() {
  hs nodes list -o json 2>/dev/null | jq -c '[.[]? | select(.given_name == "cmux" and (.online // false))][0]
    | select(. != null) | {hostname: .given_name, dns_name: (.given_name + ".test.cmux."), ips: .ip_addresses}'
}
identity() {
  for _ in $(seq 1 480); do
    local line
    line=$(hs_identity || true)
    [[ -n $line ]] && { echo "$line"; return 0; }
    sleep 0.25
  done
  return 1
}
if ID1=$(identity); then
  result PASS front-up "stable node Running $(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}')s after start: $ID1"
else
  front_log | redact | grep -iE 'tailnet|tsnet|control' | tail -30 || true
  log "headscale nodes: $(hs nodes list -o json 2>/dev/null | jq -c '[.[]? | {given_name, name, online}]' || true)"
  result FAIL front-up "stable node never Running"; exit 1
fi
for _ in $(seq 1 120); do
  [[ $(serving_count) -gt 0 ]] && break
  sleep 0.25
done
front_log | grep 'tailnet front' | sed 's/^/    /' | tail -3
SET=$(place "{\"kind\":\"set\",\"v\":1,\"workspace\":\"default\",\"placement\":{\"ssh\":\"$IP_A:7000\"}}")
log "placement set default -> backend-a $IP_A:7000: $SET"

# ---------------------------------------------------------------- client
d create --name "$CLIENT" --label "$LABEL" --network "$NET" --hostname client \
  --entrypoint /bin/sh "$TAILSCALE_IMAGE" -c \
  "exec tailscaled --tun=userspace-networking --state=mem: \
     --socket=/var/run/tailscale/tailscaled.sock \
     --socks5-server=localhost:1055 >/var/log/tailscaled.log 2>&1" >/dev/null
put_key "$CLIENT" client
d start "$CLIENT" >/dev/null
d exec "$CLIENT" apk add -q python3 >/dev/null
d cp "$HERE/move_probe.py" "$CLIENT:/root/move_probe.py"
d exec "$CLIENT" tailscale up --login-server="$CONTROL" \
  --auth-key=file:/run/cmux-tailnet/authkey --hostname=cmux-client-test --timeout=120s >/dev/null 2>&1 || true
for _ in $(seq 1 240); do
  d exec "$CLIENT" tailscale status --json 2>/dev/null \
    | jq -e '.BackendState=="Running" and ([.Peer[]? | select(.DNSName|startswith("cmux."))] | length > 0)' >/dev/null 2>&1 && break
  sleep 0.25
done
PEER=$(d exec "$CLIENT" tailscale status --json | jq -c '[.Peer[]? | select(.DNSName|startswith("cmux."))][0] | {DNSName, TailscaleIPs, CurAddr, Relay}')
log "client sees the stable node: $PEER"

# ---------------------------------------------------------------- (1) reach A
REACH=""
for _ in $(seq 1 10); do
  REACH=$(d exec "$CLIENT" python3 /root/move_probe.py cmux.test.cmux 22 0.5 0.1 2>&1 || true)
  [[ $(jq -r .first <<<"$REACH" 2>/dev/null || true) == A ]] && break
  sleep 1
done
if [[ $(jq -r .first <<<"$REACH" 2>/dev/null || true) == A ]]; then
  result PASS reach "cmux.test.cmux:22 through the tailnet -> backend A (staging VM $IP_A)"
else
  echo "    $REACH" | tail -5
  front_log | redact | grep -iE 'tailnet front|placement|dial' | tail -10 || true
  result FAIL reach "cmux:22 did not reach backend A"
fi

# ---------------------------------------------------------------- (2) move under load
log "probe ${PROBE_S}s at ${INTERVAL_S}s spacing; move default A ($IP_A) -> B ($IP_B) at ${MOVE_AT_S}s"
d exec "$CLIENT" python3 /root/move_probe.py cmux.test.cmux 22 "$PROBE_S" "$INTERVAL_S" >"$WORK/probe.json" 2>"$WORK/probe.err" &
PROBE_PID=$!
sleep "$MOVE_AT_S"
T_ASK=$(date +%s.%N)
MOVE=$(place "{\"kind\":\"moved\",\"v\":1,\"workspace\":\"default\",\"placement\":{\"ssh\":\"$IP_B:7000\"}}")
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
      "first=\(.first)"' "$WORK/probe.json" >"$WORK/numbers.txt"
  sed 's/^/    /' "$WORK/numbers.txt" | tee -a "$OUT"
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
SERVED_BEFORE=$(serving_count)
d restart -t 5 "$FRONT" >/dev/null
T0=$(date +%s.%N)
sleep 1.5
ID2=""
for _ in $(seq 1 480); do
  ID2=$(hs_identity || true)
  [[ -n $ID2 && $(serving_count) -gt $SERVED_BEFORE ]] && break
  ID2=""
  sleep 0.25
done
RESEND=$(place "{\"kind\":\"set\",\"v\":1,\"workspace\":\"default\",\"placement\":{\"ssh\":\"$IP_A:7000\"}}")
log "placement sent again after the restart: $RESEND"
RESTART_S=$(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}')
same() { jq -c '{hostname, dns_name, ips}' <<<"$1"; }
CMUX_NODES=$(hs nodes list -o json | jq '[.[]? | select(.given_name == "cmux")] | length')
AGAIN=""
for _ in $(seq 1 10); do
  AGAIN=$(d exec "$CLIENT" python3 /root/move_probe.py cmux.test.cmux 22 0.3 0.1 2>&1 || true)
  [[ $(jq -r .first <<<"$AGAIN" 2>/dev/null) == A ]] && break
  sleep 1
done
if [[ -n $ID2 && $(same "$ID1") == "$(same "$ID2")" && $CMUX_NODES == 1 && $(jq -r .first <<<"$AGAIN" 2>/dev/null) == A ]]; then
  result PASS restart "identity unchanged across restart ($(same "$ID2")); Running again ${RESTART_S}s after restart; headscale lists 1 cmux node; cmux:22 answers A again"
else
  printf '    before: %s\n    after:  %s\n    cmux nodes: %s\n    again: %s\n' "$(same "$ID1")" "$(same "${ID2:-{\}}")" "$CMUX_NODES" "$AGAIN"
  result FAIL restart "identity changed or node not back"
fi
log "headscale nodes:"
hs nodes list -o json | jq -r '.[]? | "    id=\(.id) \(.given_name) \(.ip_addresses | join(",")) online=\(.online // false)"'

[[ $FAILS == 0 ]] && log "all checks passed" || log "$FAILS check(s) failed"
exit "$FAILS"
