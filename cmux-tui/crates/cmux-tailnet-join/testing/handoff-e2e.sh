#!/usr/bin/env bash
# The identity handoff (RFD 0169) end to end, with the exact commands `cmux vm tailnet move` sends.
#
# A throwaway headscale (docker, host network) is "the user's tailnet". Two "VMs" (ubuntu containers
# with system Tailscale, tun mode, no systemd: the scripts' process path) and a "laptop" (the user's
# device). VM A joins once as `leo-cmux`, tagged. Then the node moves A -> B -> A ... MOVES times, each
# move as move_node runs it: prepare + adopt script on the target, release on the holder, state written
# 0600, detached adopt run read until it ends, forget on the old holder. Meanwhile the laptop opens a
# TCP connection to the node's Tailscale SSH port every 50 ms (0.25 s connect timeout), and with DURESS=1 each VM burns every
# core (`yes`) during the moves.
#
# VAULT=1 is `cmux vm rm` then `cmux vm tailnet adopt`: the released state goes through "the vault"
# (a file here, base64 with its sha256 checked on the way back, as the CLI does), the old VM is
# deleted (container removed) and a new one takes its place, so every adopt is on a VM that never
# held the node, and the node outlives each VM with no key.
#
# Rows: per move the gap measured on the machines (old holder stopped -> new holder Running), the gap
# the laptop saw (last answer before -> first answer after), and that the name, address and node key
# never changed and headscale still lists one cmux node. p50/p95/max at the end.
#
# Needs: docker (sudo), jq, the handoff_scripts example built (`cargo build -p cmux-tailnet-join
# --example handoff_scripts`). Cleanup removes only the containers, network and folders this script
# labelled (`cmux-handoff-e2e`); it never touches the host's tailscaled.
set -euo pipefail

MOVES=${MOVES:-20}
DURESS=${DURESS:-1}
VAULT=${VAULT:-0}
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS=${SCRIPTS:-$HERE/../../../target/debug/examples/handoff_scripts}
TS_IMAGE=tailscale/tailscale:v1.84.3
HS_IMAGE=headscale/headscale:0.26.1
PORT=${HS_PORT:-18181}
WORK=$(mktemp -d /tmp/cmux-handoff-e2e.XXXXXX)
LABEL=cmux-handoff-e2e
D="sudo docker"
LOGIN=http://172.17.0.1:$PORT

cleanup() {
  [ -n "${KEEP_PROBE:-}" ] && $D logs che-probe >"$KEEP_PROBE" 2>&1 || true
  $D ps -aq --filter "label=$LABEL" | xargs -r $D rm -f >/dev/null 2>&1 || true
  sudo rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '== %s\n' "$*" >&2; }

# The "VM" image: ubuntu with Tailscale's binaries (what the join's install script puts on a VM).
$D build -q -t cmux-handoff-e2e-vm --label $LABEL - >/dev/null <<EOF
FROM $TS_IMAGE AS ts
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq procps iproute2 ca-certificates jq >/dev/null && rm -rf /var/lib/apt/lists/*
COPY --from=ts /usr/local/bin/tailscale /usr/local/bin/tailscaled /usr/bin/
EOF

say "headscale on :$PORT"
mkdir -p "$WORK/hs/config" "$WORK/hs/data"
cat >"$WORK/hs/config/config.yaml" <<EOF
server_url: $LOGIN
listen_addr: 0.0.0.0:$PORT
metrics_listen_addr: 127.0.0.1:0
grpc_listen_addr: 127.0.0.1:0
noise: { private_key_path: /var/lib/headscale/noise_private.key }
prefixes: { v4: 100.64.0.0/10, v6: fd7a:115c:a1e0::/48, allocation: sequential }
derp:
  server: { enabled: false }
  urls: [https://controlplane.tailscale.com/derpmap/default]
  auto_update_enabled: false
database: { type: sqlite, sqlite: { path: /var/lib/headscale/db.sqlite } }
dns: { magic_dns: true, base_domain: user.example, nameservers: { global: [1.1.1.1] } }
policy: { mode: file, path: /etc/headscale/policy.hujson }
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
EOF
cat >"$WORK/hs/config/policy.hujson" <<'EOF'
{
  "tagOwners": { "tag:cmux": ["leo@"] },
  "acls": [ { "action": "accept", "src": ["leo@"], "dst": ["tag:cmux:*"] } ],
  "ssh": [ { "action": "accept", "src": ["leo@"], "dst": ["tag:cmux"], "users": ["root"] } ]
}
EOF
$D run -d --label $LABEL --name che-hs --network host -v "$WORK/hs/config:/etc/headscale" -v "$WORK/hs/data:/var/lib/headscale" $HS_IMAGE serve >/dev/null
HS="$D exec che-hs headscale"
for _ in $(seq 50); do $HS users list >/dev/null 2>&1 && break; sleep 0.2; done
$HS users create leo >/dev/null
KEY_NODE=$($HS preauthkeys create --user 1 --tags tag:cmux --expiration 1h -o json | jq -r .key)
KEY_LAPTOP=$($HS preauthkeys create --user 1 --expiration 1h -o json | jq -r .key)

say "laptop and two VMs"
$D run -d --label $LABEL --name che-laptop --hostname leo-laptop --init --cap-add NET_ADMIN --device /dev/net/tun \
  -e TS_AUTHKEY="$KEY_LAPTOP" -e TS_EXTRA_ARGS="--login-server=$LOGIN" -e TS_USERSPACE=false -e TS_HOSTNAME=leo-laptop \
  -e TS_STATE_DIR=/var/lib/tailscale $TS_IMAGE >/dev/null
new_vm() {
  $D run -d --label $LABEL --name che-vm-$1 --hostname vm-$1 --init --cap-add NET_ADMIN --device /dev/net/tun \
    cmux-handoff-e2e-vm sleep infinity >/dev/null
}
for vm in a b; do new_vm $vm; done

vm() { local name=$1; shift; $D exec -i "che-vm-$name" bash -c "$*"; }

say "VM a joins once as leo-cmux (tagged, Tailscale SSH)"
vm a 'mkdir -p /var/lib/tailscale /var/run/tailscale; setsid tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock </dev/null >/var/log/tsd.log 2>&1 &
  for i in $(seq 50); do tailscale status >/dev/null 2>&1 && break; tailscale status 2>&1 | grep -qi "logged out\|needslogin" && break; sleep 0.2; done'
vm a "tailscale up --login-server=$LOGIN --auth-key=$KEY_NODE --hostname=leo-cmux --ssh --accept-dns=false" >/dev/null
for _ in $(seq 100); do $D exec che-laptop tailscale status >/dev/null 2>&1 && break; sleep 0.2; done

ident() { vm "$1" 'tailscale status --json --peers=false | jq -r "[.Self.HostName, .Self.TailscaleIPs[0], .Self.PublicKey] | join(\" \")"'; }
IDENT0=$(ident a)
NODE_IP=$(echo "$IDENT0" | cut -d' ' -f2)
say "node: $IDENT0"

# The laptop's view: a TCP connect to the node's port 22 (Tailscale SSH) every 50 ms, one line per
# try: "<epoch ms> ok|no". Run from a VM-image container in the laptop's network namespace (bash, ms clock).
$D run -d --label $LABEL --name che-probe --network container:che-laptop cmux-handoff-e2e-vm bash -c "
  while :; do t=\${EPOCHREALTIME/./}; t=\${t:0:13}
    if timeout 0.25 bash -c 'exec 3<>/dev/tcp/$NODE_IP/22' 2>/dev/null; then echo \"\$t ok\"; else echo \"\$t no\"; fi
    sleep 0.05; done" >/dev/null
for _ in $(seq 100); do $D logs che-probe 2>/dev/null | grep -c ' ok$' >/dev/null && break; sleep 0.2; done
$D logs che-probe 2>/dev/null | grep -c ' ok$' >/dev/null || { echo "the laptop never reached the node" >&2; exit 1; }

burn() { vm "$1" 'for i in $(seq $(nproc)); do (nice -n 0 yes >/dev/null &) ; done'; }
if [ "$DURESS" = 1 ]; then
  say "duress: every core busy on both VMs"
  for v in a b; do burn $v; done
fi

PREPARE=$($SCRIPTS prepare); RELEASE=$($SCRIPTS release); ADOPT=$($SCRIPTS adopt)
START=$($SCRIPTS start); READ=$($SCRIPTS read); FORGET=$($SCRIPTS forget)

ROWS="$WORK/rows"; : >"$ROWS"
holder=a
for n in $(seq "$MOVES"); do
  target=$([ $holder = a ] && echo b || echo a)
  # move_node's order: ready the target, release the holder, write the state 0600, start, read.
  vm $target "$PREPARE" | grep -qx prepared
  printf '%s' "$ADOPT" | vm $target 'cat >/run/cmux-tailnet/join.sh; chmod 700 /run/cmux-tailnet/join.sh'
  released=$(vm $holder "$RELEASE")
  echo "$released" | grep -qx cmux-tailnet-released || { echo "move $n: release failed: $released" >&2; exit 1; }
  stopped=$(echo "$released" | sed -n 's/^cmux-tailnet-stopped-at //p')
  if [ "$VAULT" = 1 ]; then
    # Into the vault with its fingerprint; the old VM is deleted; back out, checked, to the new one.
    echo "$released" | sed -n 's/^cmux-tailnet-state //p' | (umask 077; cat >"$WORK/vault.b64")
    print=$(base64 -d <"$WORK/vault.b64" | sha256sum | cut -d' ' -f1)
    $D rm -f che-vm-$holder >/dev/null
    [ "$(base64 -d <"$WORK/vault.b64" | sha256sum | cut -d' ' -f1)" = "$print" ] || { echo "move $n: vault copy changed" >&2; exit 1; }
    vm $target 'umask 077; cat >/run/cmux-tailnet/node.state' <"$WORK/vault.b64"
  else
    echo "$released" | sed -n 's/^cmux-tailnet-state //p' | vm $target 'umask 077; cat >/run/cmux-tailnet/node.state'
  fi
  vm $target "$START" | grep -qx started
  answer=""
  for _ in $(seq 600); do
    answer=$(vm $target "$READ")
    head -n1 <<<"$answer" | grep -q '^rc=[0-9]' && break
    sleep 0.25
  done
  head -n1 <<<"$answer" | grep -qx 'rc=0' || { echo "move $n: adopt failed: $answer" >&2; exit 1; }
  online=$(echo "$answer" | sed -n 's/^cmux-tailnet-online-at //p')
  if [ "$VAULT" = 1 ]; then
    # The deleted VM's replacement: a fresh machine that never held the node.
    new_vm $holder
    [ "$DURESS" = 1 ] && burn $holder
  else
    vm $holder "$FORGET" | grep -qx cmux-tailnet-forgot
    vm $holder "test ! -e /var/lib/tailscale/tailscaled.state" || { echo "move $n: old copy left" >&2; exit 1; }
  fi
  vm $target "test ! -e /run/cmux-tailnet/node.state" || { echo "move $n: staged state left" >&2; exit 1; }
  ident_now=$(ident $target)
  [ "$(cut -d' ' -f2,3 <<<"$ident_now")" = "$(cut -d' ' -f2,3 <<<"$IDENT0")" ] || { echo "move $n: identity changed: $ident_now vs $IDENT0" >&2; exit 1; }
  nodes=$($HS nodes list -o json | jq '[.[] | select(.given_name == "leo-cmux" or .name == "leo-cmux")] | length')
  # The laptop's answer again, then its gap: last ok at or before the stop -> first ok after it.
  seen=""
  for _ in $(seq 300); do
    $D logs che-probe >"$WORK/probe" 2>/dev/null || true
    seen=$(awk -v s="$stopped" '$1 > s && $2 == "ok" {print $1; exit}' "$WORK/probe")
    [ -n "$seen" ] && break; sleep 0.1
  done
  last_ok=$(awk -v s="$stopped" '$1 <= s && $2 == "ok" {t=$1} END {print t}' "$WORK/probe")
  laptop_gap=$(( ${seen:-0} - ${last_ok:-0} ))
  printf 'move %2d %s->%s gap_ms=%d laptop_gap_ms=%d same_identity=yes cmux_nodes=%s stopped=%s online=%s last_ok=%s seen=%s\n' \
    "$n" $holder $target $((online - stopped)) "$laptop_gap" "$nodes" "$stopped" "$online" "$last_ok" "$seen" | tee -a "$ROWS"
  [ "$nodes" = 1 ] || { echo "move $n: headscale lists $nodes cmux nodes" >&2; exit 1; }
  holder=$target
  sleep 1
done

stats() {
  sed -n "s/.* $1=\([0-9]*\).*/\1/p" "$ROWS" | sort -n | awk -v k="$1" '{a[NR]=$1} END {
    p50=a[int((NR+1)*0.50)]; i=int(NR*0.95+0.999); if (i>NR) i=NR; p95=a[i];
    printf "%s: n=%d p50=%d p95=%d max=%d\n", k, NR, p50, p95, a[NR]}'
}
echo "vault=$VAULT duress=$DURESS moves=$MOVES identity=$(cut -d' ' -f1,2 <<<"$IDENT0") nodekey=$(cut -d' ' -f3 <<<"$IDENT0" | cut -c1-20)"
stats gap_ms
stats laptop_gap_ms
