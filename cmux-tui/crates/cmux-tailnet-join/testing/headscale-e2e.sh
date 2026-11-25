#!/usr/bin/env bash
# Throwaway-tailnet end-to-end test for cmux-tailnet-join.
#
# Spins up, on a private docker network, all labelled with a unique run id:
#   headscale  - headscale/headscale control server (sqlite, MagicDNS base_domain
#                test.cmux, embedded DERP over plain HTTP, no internet DERP map)
#   vm         - a tailscale node standing in for an AutoCloud VM; runs
#                $JOIN_SCRIPT (or the default join) as root with the auth key
#                mounted read-only at /run/cmux-tailnet/authkey (0600)
#   eph        - a second "vm" joined with an ephemeral key (removal on stop)
#   client     - another tailscale node that probes the vm
# and checks from the client:
#   (a) MagicDNS: cmux-vm-test resolves (status, tailscale ip, dns query, ping)
#   (b) Tailscale SSH: tailscale ssh root@cmux-vm-test true
#   (c) Serve: http://cmux-vm-test/ through the client's userspace HTTP proxy
#   (d) Leave: $LEAVE_SCRIPT (default: tailscale logout) drops the vm from
#       headscale; stopping the ephemeral container removes its node too
#
# It never touches the host's tailscaled: every tailscaled here runs inside a
# container with --tun=userspace-networking. Cleanup (trap) removes only the
# containers and network carrying this run's label.
#
# Usage: headscale-e2e.sh            (env: JOIN_SCRIPT, LEAVE_SCRIPT, KEEP=1,
#                                     HEADSCALE_IMAGE, TAILSCALE_IMAGE,
#                                     EPHEMERAL_WAIT_S)
# Exit status: 0 when every check passed.
set -euo pipefail

HEADSCALE_IMAGE=${HEADSCALE_IMAGE:-headscale/headscale:0.27.1}
TAILSCALE_IMAGE=${TAILSCALE_IMAGE:-tailscale/tailscale:stable}
EPHEMERAL_WAIT_S=${EPHEMERAL_WAIT_S:-150}
RUN_ID="cmux-tailnet-e2e-$(date +%s)-$$-$RANDOM"
LABEL="cmux.tailnet-e2e.run=$RUN_ID"
NET="$RUN_ID"
HS="$RUN_ID-headscale"
VM="$RUN_ID-vm"
EPH="$RUN_ID-eph"
CLIENT="$RUN_ID-client"

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  echo "FAIL setup: cannot reach docker (neither docker nor sudo -n docker)" >&2
  exit 2
fi
d() { "${DOCKER[@]}" "$@"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmux-tailnet-e2e.XXXXXX")
chmod 700 "$WORK"
mkdir -m 700 "$WORK/keys"

FAILS=0
RESULTS=()
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
result() { # result PASS|FAIL name detail
  RESULTS+=("$1 $2${3:+ - $3}")
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

log "run $RUN_ID: images $HEADSCALE_IMAGE, $TAILSCALE_IMAGE"
d network create --label "$LABEL" "$NET" >/dev/null
d create --name "$HS" --label "$LABEL" --network "$NET" --network-alias headscale \
  "$HEADSCALE_IMAGE" serve >/dev/null
d cp "$WORK/config.yaml" "$HS:/etc/headscale/config.yaml" 2>/dev/null || {
  # /etc/headscale may not exist in the image; copy a directory instead.
  mkdir -p "$WORK/etc-headscale"
  cp "$WORK/config.yaml" "$WORK/policy.json" "$WORK/etc-headscale/"
  d cp "$WORK/etc-headscale/." "$HS:/etc/headscale/"
}
d cp "$WORK/policy.json" "$HS:/etc/headscale/policy.json"
d start "$HS" >/dev/null
hs() { d exec "$HS" headscale "$@"; }
for _ in $(seq 1 60); do
  hs users list >/dev/null 2>&1 && break
  sleep 0.5
done
if ! hs users list >/dev/null 2>&1; then
  d logs "$HS" 2>&1 | tail -30
  result FAIL setup "headscale did not come up"
  exit 1
fi
hs users create cmux >/dev/null
USER_ID=$(hs users list -o json | jq -r '.[] | select(.name=="cmux") | .id')
# Keys go straight to files in a 0700 dir; never to stdout.
( umask 077
  hs preauthkeys create --user "$USER_ID" --reusable --expiration 1h -o json \
    | jq -r .key >"$WORK/keys/reusable"
  hs preauthkeys create --user "$USER_ID" --ephemeral --expiration 1h -o json \
    | jq -r .key >"$WORK/keys/ephemeral" )
[[ -s $WORK/keys/reusable && -s $WORK/keys/ephemeral ]] || {
  result FAIL setup "could not mint pre-auth keys"; exit 1; }
log "headscale up; user cmux id=$USER_ID; keys in $WORK/keys (0600)"

# ---------------------------------------------------------------- nodes
# start_node NAME KEYFILE STATE: a tailscale container with userspace networking,
# SOCKS5 on :1055 and an HTTP proxy on :1056 (both localhost-only), DERP over
# plain HTTP since the embedded DERP shares headscale's http listener.
start_node() {
  local name=$1 key=$2 state=$3
  d run -d --name "$name" --label "$LABEL" --network "$NET" \
    --hostname "${name##*-}" \
    -e TS_DEBUG_USE_DERP_HTTP=1 \
    -v "$key:/run/cmux-tailnet/authkey:ro" \
    --entrypoint /bin/sh "$TAILSCALE_IMAGE" -c \
    "exec tailscaled --tun=userspace-networking --state=$state \
       --socket=/var/run/tailscale/tailscaled.sock \
       --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1056 \
       >/var/log/tailscaled.log 2>&1" >/dev/null
}
chmod 600 "$WORK/keys/reusable" "$WORK/keys/ephemeral"
start_node "$VM" "$WORK/keys/reusable" /var/lib/tailscale/tailscaled.state
start_node "$EPH" "$WORK/keys/ephemeral" mem:
start_node "$CLIENT" "$WORK/keys/reusable" /var/lib/tailscale/tailscaled.state

# Tools the default join script and the probes need (python3 for the served
# app, openssh-client for `tailscale ssh`, curl and bind-tools for probes).
log "installing python3/openssh-client/curl in node containers"
d exec "$VM" apk add -q python3 curl >/dev/null &
d exec "$CLIENT" apk add -q openssh-client curl bind-tools >/dev/null &
wait

wait_running() { # wait_running CONTAINER TIMEOUT_S -> 0 when BackendState=Running
  local c=$1 t=$2 s
  for _ in $(seq 1 $((t * 4))); do
    s=$(d exec "$c" tailscale status --json 2>/dev/null | jq -r .BackendState 2>/dev/null || true)
    [[ $s == Running ]] && return 0
    sleep 0.25
  done
  return 1
}
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

DEFAULT_JOIN=$(cat <<'EOF'
#!/bin/sh
set -eu
tailscale up --login-server=http://headscale:8080 \
  --auth-key=file:/run/cmux-tailnet/authkey --hostname=cmux-vm-test --ssh
mkdir -p /srv/www
echo "cmux-tailnet-e2e served page" >/srv/www/index.html
cd /srv/www
nohup python3 -m http.server 8000 --bind 127.0.0.1 >/var/log/http.log 2>&1 &
for i in $(seq 1 40); do
  wget -qO- http://127.0.0.1:8000/ >/dev/null 2>&1 && break
  sleep 0.25
done
tailscale serve --bg --http=80 http://127.0.0.1:8000
EOF
)
if [[ -n ${JOIN_SCRIPT:-} ]]; then
  cp -- "$JOIN_SCRIPT" "$WORK/join.sh"
else
  printf '%s\n' "$DEFAULT_JOIN" >"$WORK/join.sh"
fi
d cp "$WORK/join.sh" "$VM:/root/join.sh"
d exec "$VM" chmod 700 /root/join.sh

log "vm: running ${JOIN_SCRIPT:-default join script}"
T0=$(now)
if d exec "$VM" /root/join.sh >"$WORK/join.log" 2>&1 && wait_running "$VM" 60; then
  T1=$(now)
  result PASS join "vm Running $(elapsed "$T0" "$T1")s after join start (join script incl. serve)"
else
  sed 's/tskey-[A-Za-z0-9-]*/tskey-REDACTED/g; s/hskey-[A-Za-z0-9_-]*/hskey-REDACTED/g' "$WORK/join.log" | tail -20
  result FAIL join "vm never reached Running"
fi

T0=$(now)
d exec "$CLIENT" tailscale up --login-server=http://headscale:8080 \
  --auth-key=file:/run/cmux-tailnet/authkey --hostname=cmux-client-test >/dev/null 2>&1 || true
if wait_running "$CLIENT" 60; then
  result PASS join-client "client Running $(elapsed "$T0" "$(now)")s after tailscale up"
else
  result FAIL join-client "client never reached Running"
fi

T0=$(now)
d exec "$EPH" tailscale up --login-server=http://headscale:8080 \
  --auth-key=file:/run/cmux-tailnet/authkey --hostname=cmux-eph-test >/dev/null 2>&1 || true
if wait_running "$EPH" 60; then
  result PASS join-ephemeral "ephemeral node Running $(elapsed "$T0" "$(now)")s after tailscale up"
else
  result FAIL join-ephemeral "ephemeral node never reached Running"
fi

node_present() { # node_present HOSTNAME -> "id online=BOOL expired=BOOL" or nothing
  hs nodes list -o json 2>/dev/null \
    | jq -r --arg h "$1" --argjson now "$(date +%s)" '.[]? | select(.given_name==$h or .name==$h)
        | "\(.id) online=\(.online // false) expired=\((.expiry.seconds // 0) > 0 and (.expiry.seconds // 0) <= $now)"' | head -1
}
nodes_table() {
  hs nodes list -o json 2>/dev/null | jq -r '.[]? | "    id=\(.id) \(.given_name) \(.ip_addresses | join(",")) online=\(.online // false) expiry=\(.expiry.seconds // 0) user=\(.user.name)"'
}
client_sees_vm() { # true while the client holds a live (unexpired) netmap entry for the vm
  cx tailscale status --json 2>/dev/null \
    | jq -e '[.Peer[]? | select((.DNSName|startswith("cmux-vm-test.")) and (.Expired != true))] | length > 0' >/dev/null 2>&1
}
log "headscale nodes:"
nodes_table

cx() { d exec "$CLIENT" "$@"; }

# ---------------------------------------------------------------- (a) MagicDNS
# Wait for the vm to show up in the client's netmap first.
for _ in $(seq 1 80); do
  cx tailscale status --json 2>/dev/null \
    | jq -e '.Peer[]? | select(.HostName=="cmux-vm-test" or (.DNSName|startswith("cmux-vm-test.")))' >/dev/null 2>&1 && break
  sleep 0.25
done
VM_DNS=$(cx tailscale status --json | jq -r '[.Peer[]? | select(.DNSName|startswith("cmux-vm-test."))][0].DNSName // empty')
VM_IP=$(cx tailscale ip -4 cmux-vm-test 2>/dev/null || true)
DNSQ=$(cx tailscale dns query cmux-vm-test.test.cmux 2>/dev/null || true)
DNSQ_IP=$(grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' <<<"$DNSQ" | head -1 || true)
PING=$(cx tailscale ping -c 5 --timeout 5s cmux-vm-test 2>&1 || true)
PING_OK=$(grep -cE '^pong from cmux-vm-test' <<<"$PING" || true)
if [[ $VM_DNS == cmux-vm-test.test.cmux. && -n $VM_IP && $DNSQ_IP == "$VM_IP" && $PING_OK -ge 1 ]]; then
  result PASS magicdns "$VM_DNS -> $VM_IP (status, tailscale ip, dns query via 100.100.100.100 resolver); $(grep -E '^pong' <<<"$PING" | tail -1)"
else
  printf '    status DNSName=%q ip=%q dnsquery=%q\n' "$VM_DNS" "$VM_IP" "$DNSQ_IP"
  sed 's/^/    ping: /' <<<"$PING" | tail -5
  result FAIL magicdns "cmux-vm-test did not resolve/answer"
fi

# ---------------------------------------------------------------- (b) SSH
# `tailscale ssh` takes no ssh -o flags before the host; it checks the host key
# against the one the coordination server advertises, and in userspace mode
# supplies `tailscale nc` as ProxyCommand to the system ssh (openssh-client).
SSH_OUT=$(cx timeout 30 tailscale ssh root@cmux-vm-test 'echo ssh-ok-$(hostname)' </dev/null 2>&1 || true)
if grep -q '^ssh-ok-' <<<"$SSH_OUT"; then
  result PASS ssh "tailscale ssh root@cmux-vm-test -> $(grep '^ssh-ok-' <<<"$SSH_OUT" | head -1)"
else
  sed 's/^/    ssh: /' <<<"$SSH_OUT" | tail -10
  result FAIL ssh "tailscale ssh root@cmux-vm-test failed"
fi

# ---------------------------------------------------------------- (c) Serve
SERVE_HTTP=$(cx curl -fsS --max-time 15 -x http://localhost:1056 http://cmux-vm-test/ 2>&1 || true)
SERVE_SOCKS=$(cx curl -fsS --max-time 15 --socks5-hostname localhost:1055 http://cmux-vm-test.test.cmux/ 2>&1 || true)
if [[ $SERVE_HTTP == *"cmux-tailnet-e2e served page"* && $SERVE_SOCKS == *"cmux-tailnet-e2e served page"* ]]; then
  result PASS serve "http://cmux-vm-test/ via HTTP proxy and SOCKS5 -> '$SERVE_HTTP'"
else
  printf '    http-proxy: %s\n    socks5: %s\n' "$SERVE_HTTP" "$SERVE_SOCKS"
  d exec "$VM" tailscale serve status 2>&1 | sed 's/^/    vm serve: /'
  result FAIL serve "served page not reachable through the tailnet"
fi

# ---------------------------------------------------------------- (d) Leave
DEFAULT_LEAVE='#!/bin/sh
set -eu
tailscale serve reset || true
tailscale logout'
if [[ -n ${LEAVE_SCRIPT:-} ]]; then
  cp -- "$LEAVE_SCRIPT" "$WORK/leave.sh"
else
  printf '%s\n' "$DEFAULT_LEAVE" >"$WORK/leave.sh"
fi
d cp "$WORK/leave.sh" "$VM:/root/leave.sh"
d exec "$VM" chmod 700 /root/leave.sh
BEFORE=$(node_present cmux-vm-test)
T0=$(now)
d exec "$VM" /root/leave.sh >"$WORK/leave.log" 2>&1 || true
# headscale (0.27) keeps a non-ephemeral node's row after `tailscale logout`: it
# sets the node's expiry to now, so it shows Expired=yes, offline, and drops out
# of every peer's netmap. tailscale.com behaves the same for non-ephemeral
# nodes. So "left" here means: gone from headscale, or expired+offline there AND
# expired in the client's netmap (the client keeps the peer row with
# Expired=true and `tailscale ping` answers "peer's node key has expired"). An ephemeral node's row is deleted outright.
LEFT= AFTER=
for _ in $(seq 1 60); do
  AFTER=$(node_present cmux-vm-test)
  if [[ -z $AFTER ]]; then LEFT="row deleted"; break; fi
  if [[ $AFTER == *"online=false expired=true"* ]] && ! client_sees_vm; then
    LEFT="row kept but expired+offline; client netmap marks it expired"; break
  fi
  sleep 0.25
done
LPING=$(cx tailscale ping -c 1 --timeout 3s cmux-vm-test 2>&1 || true)
if [[ -n $BEFORE && -n $LEFT && $LPING != pong* ]]; then
  LEFT="$LEFT; client ping: $(head -1 <<<"$LPING")"
  result PASS leave "vm left the tailnet $(elapsed "$T0" "$(now)")s after leave script ($LEFT; before: $BEFORE, after: ${AFTER:-none})"
else
  sed 's/tskey-[A-Za-z0-9-]*/tskey-REDACTED/g; s/^/    leave: /' "$WORK/leave.log" | tail -5
  printf '    before: %s\n    after: %s\n' "$BEFORE" "$AFTER"
  result FAIL leave "vm still on the tailnet after leave script"
fi

EBEFORE=$(node_present cmux-eph-test)
# EPH_STOP=stop (SIGTERM, a clean shutdown) or kill (SIGKILL, like a VM that
# is destroyed without notice: headscale then waits out the 66s inactivity
# timeout).
d "${EPH_STOP:-stop}" "$EPH" >/dev/null
T0=$(now)
GONE=
for _ in $(seq 1 $((EPHEMERAL_WAIT_S * 2))); do
  [[ -z $(node_present cmux-eph-test) ]] && { GONE=1; break; }
  sleep 0.5
done
if [[ -n $EBEFORE && -n $GONE ]]; then
  result PASS leave-ephemeral "ephemeral node removed $(elapsed "$T0" "$(now)")s after docker ${EPH_STOP:-stop} (inactivity timeout 66s)"
else
  printf '    before: %s\n    after: %s\n' "$EBEFORE" "$(node_present cmux-eph-test)"
  result FAIL leave-ephemeral "ephemeral node still listed ${EPHEMERAL_WAIT_S}s after stop"
fi

log "headscale nodes after leave:"
nodes_table

echo "---- summary ($RUN_ID)"
printf '%s\n' "${RESULTS[@]}"
if ((FAILS == 0)); then echo "ALL PASS"; else echo "$FAILS FAILED"; exit 1; fi
