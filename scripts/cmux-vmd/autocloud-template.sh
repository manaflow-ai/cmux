#!/usr/bin/env bash
# autocloud-template.sh: bake the `autocloud` template that cmux-vmd's own-host Cloud machines restore from.
#
# Run it on a cmux-vmd host (root via sudo, curl, jq), with the daemon listening:
#   bash scripts/cmux-vmd/autocloud-template.sh            # or: ssh HOST 'bash -s' < scripts/cmux-vmd/autocloud-template.sh
# Env: VMD (http://127.0.0.1:7070), TOKEN_FILE (/etc/cmux-vmd/token), IMAGE (autocloud), VCPUS (2), MEM_MIB (4096),
#      TEMPLATES (the names the snapshot is set as; default "autocloud autocloud@2x4096").
#
# It boots one machine from the image, makes it hold what cmux-host's first bind needs (`bind_now` in
# cmux-tui/crates/cmux-host/src/cloud/role.rs), checks each of those steps in the guest, snapshots it and points
# the templates at the snapshot. The regular Cloud image bake (web/scripts/cmux-vm-image/bake.ts) does the same
# work for the other providers; this is its cmux-vmd counterpart, one step per bind_now step:
#   install key  /var/lib/cmux writable, no per-machine file baked in (bake.ts PER_MACHINE_FILES)
#   wg key       `wg genkey | wg pubkey` (wireguard-tools, pinned as images/cmux-vm/inputs.lock.json pins it)
#   daemon info  /etc/cmux/daemon-socket and /etc/cmux/daemon.json, recorded from the running daemon the way
#                bake.ts recordDaemonInfo does (wire.rs DAEMON_SOCKET_FILE, DAEMON_INFO_FILE)
#   JsonPoster   a CA bundle and HTTPS egress
#   Noise key    /etc/cmux/daemon-layout and the cloud session's identity.json under the home it names
#   updater      /opt/cmux/current/bin/cmux resolves (before_first_bind adopts from it)
# Any failed check stops the bake before the snapshot, and the machine is deleted.
# Prints one JSON line at the end: {machine, snapshot, templates, checks, timing}.
set -euo pipefail

VMD="${VMD:-http://127.0.0.1:7070}"
TOKEN_FILE="${TOKEN_FILE:-/etc/cmux-vmd/token}"
IMAGE="${IMAGE:-autocloud}"
VCPUS="${VCPUS:-2}"
MEM_MIB="${MEM_MIB:-4096}"
TEMPLATES="${TEMPLATES:-autocloud autocloud@2x4096}"
# images/cmux-vm/inputs.lock.json basePackages."wireguard-tools" (tests/test_cmux_vmd_autocloud_template.py keeps them equal).
WG_TOOLS_VERSION="1.0.20210914-1ubuntu4"
# bake.ts PER_MACHINE_FILES: a snapshot holding one gives it to every clone (same test keeps the lists equal).
PER_MACHINE_FILES="/var/lib/cmux/bind.json /var/lib/cmux/bound.json /var/lib/cmux/install/key.json /var/lib/cmux/install/identity.json /var/lib/cmux/wg/key.json /var/lib/cmux/carrier.json /run/cmux/carrier-grant.json /etc/cmux/daemon-instance-id"
HOST_CLI="/opt/cmux/current/bin/cmux host"

TOKEN="$(sudo cat "$TOKEN_FILE")"
api() { curl -sS -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
# guest ID COMMAND [TIMEOUT_MS]: run COMMAND as root in the guest; prints stdout+stderr, returns its exit code.
guest() {
  local r
  r="$(api -X POST "$VMD/v1/vms/$1/exec" -d "$(jq -n --arg c "$2" --argjson t "${3:-60000}" '{command:$c, timeout_ms:$t}')")"
  printf '%s' "$r" | jq -r '((.stdout_b64 // "")|@base64d) + ((.stderr_b64 // "")|@base64d)'
  return "$(printf '%s' "$r" | jq -r '.exit_code // .code // 1')"
}
now_ms() { date +%s%3N; }

for _ in $(seq 30); do curl -sf "$VMD/healthz" >/dev/null && break; sleep 1; done
curl -sf "$VMD/healthz" >/dev/null || { echo "cmux-vmd does not answer at $VMD" >&2; exit 1; }

t0=$(now_ms)
created="$(api -X POST "$VMD/v1/machines" -d "$(jq -n --arg i "$IMAGE" --argjson c "$VCPUS" --argjson m "$MEM_MIB" \
  '{name:"autocloud-template", image:$i, vcpus:$c, mem_mib:$m, egress:{mode:"internet"}}')")"
id="$(printf '%s' "$created" | jq -r '.machine.id // empty')"
[ -n "$id" ] || { echo "create refused: $(printf '%s' "$created" | jq -c '.error // .')" >&2; exit 1; }
create_ms=$(( $(now_ms) - t0 ))
snapshotted=""
cleanup() { [ -n "$snapshotted" ] || api -X DELETE "$VMD/v1/machines/$id" >/dev/null || true; }
trap cleanup EXIT

state=""
for _ in $(seq 90); do
  state="$(guest "$id" 'systemctl is-system-running' 2>/dev/null || true)"
  case "$state" in running*|degraded*) break ;; esac
  sleep 2
done
case "$state" in running*|degraded*) ;; *) echo "guest never came up (systemd: ${state:-no answer})" >&2; exit 1 ;; esac
boot_ms=$(( $(now_ms) - t0 - create_ms ))

# /etc/cmux as the regular image has it: root's, not group or world writable (cmux-host refuses to trust it otherwise).
guest "$id" 'chmod 755 /etc/cmux && chmod go-w /etc/cmux/* && systemctl restart cmux-host' >/dev/null

# wg key: wireguard-tools at the regular image's pinned version.
guest "$id" "command -v wg >/dev/null || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends wireguard-tools=$WG_TOOLS_VERSION >/dev/null; }; dpkg-query -W -f='\${Version}\n' wireguard-tools" 300000

# daemon info: the running daemon's control socket (found by ss, as bake.ts does) and its identify answer.
daemon_info="$(guest "$id" "$(cat <<EOF
set -e
for i in \$(seq 1 60); do
  sock="\$(ss -Hxlp | awk '/"cmux-tui"/ {for (i = 1; i <= NF; i++) if (\$i ~ /\\/cloud\\.sock\$/) print \$i}' | head -1)"
  [ -n "\$sock" ] && break; sleep 1
done
test -n "\$sock"
printf '%s\n' "\$sock" > /etc/cmux/daemon-socket
$HOST_CLI cloud daemon-info > /etc/cmux/daemon.json.tmp
mv /etc/cmux/daemon.json.tmp /etc/cmux/daemon.json
chmod 0644 /etc/cmux/daemon.json /etc/cmux/daemon-socket
cat /etc/cmux/daemon.json
EOF
)" 90000)"
printf '%s' "$daemon_info" | jq -e '(.version // "unknown" | startswith("unknown") | not) and ((.capabilities // []) | index("vm-agent-v1") and index("loopback-forward-v1"))' >/dev/null \
  || { echo "daemon.json is not a real identify answer: ${daemon_info:0:300}" >&2; exit 1; }

# Every bind_now step, in the guest. One line per step: `ok STEP` or `FAIL STEP: why`.
checks="$(guest "$id" "$(cat <<EOF
fail=0
step() { if eval "\$2" >/dev/null 2>&1; then echo "ok \$1"; else echo "FAIL \$1: \$3"; fail=1; fi; }
held=""; for f in $PER_MACHINE_FILES; do [ -e "\$f" ] && held="\$held \$f"; done
step install-key 'mkdir -p /var/lib/cmux && test -w /var/lib/cmux && test -z "\$held"' "per-machine files baked in:\$held"
step wg-key 'test -n "\$(wg genkey | wg pubkey)"' "wg genkey | wg pubkey failed (wireguard-tools)"
step daemon-socket 'test -S "\$(head -n 1 /etc/cmux/daemon-socket)"' "/etc/cmux/daemon-socket names no socket"
step daemon-json 'python3 -c "import json; d=json.load(open(\"/etc/cmux/daemon.json\")); assert d[\"version\"] and d[\"capabilities\"]"' "/etc/cmux/daemon.json unreadable"
step json-poster 'test -s /etc/ssl/certs/ca-certificates.crt && curl -sS -m 10 -o /dev/null https://example.com' "no CA bundle or no HTTPS egress"
# Noise key (role.rs daemon_noise_key): /etc/cmux/daemon-layout names the home, which holds the cloud session's identity.
home=""; case "\$(tr -d '[:space:]' < /etc/cmux/daemon-layout 2>/dev/null)" in root) home=/root ;; user) home=/home/cmux ;; esac
step noise-key 'test -n "\$home" && test -s "\$home/.local/state/cmux/remote/sessions/Y2xvdWQ/auth/identity.json"' "no /etc/cmux/daemon-layout or no cloud session identity under it"
step updater '$HOST_CLI --help' "/opt/cmux/current/bin/cmux does not run"
step clock 'test \$(( \$(date +%s) - $(date +%s) )) -le 30 && test \$(( $(date +%s) - \$(date +%s) )) -le 30' "guest clock is more than 30 s off the host's"
exit \$fail
EOF
)" 60000)" || { printf '%s\n' "$checks" >&2; echo "a bind step would fail on this image; no snapshot taken" >&2; exit 1; }
printf '%s\n' "$checks" >&2

guest "$id" 'sync' >/dev/null
t1=$(now_ms)
snap="$(api -X POST "$VMD/v1/machines/$id/snapshot" -d '{}')"
sid="$(printf '%s' "$snap" | jq -r '.snapshot.id // empty')"
[ -n "$sid" ] || { echo "snapshot refused: $(printf '%s' "$snap" | jq -c '.error // .')" >&2; exit 1; }
snapshotted=1
snapshot_ms=$(( $(now_ms) - t1 ))
for t in $TEMPLATES; do
  api -X PUT "$VMD/v1/templates/$t" -d "$(jq -n --arg s "$sid" '{snapshot_id:$s}')" | jq -e '.error | not' >/dev/null \
    || { echo "template $t refused the snapshot" >&2; exit 1; }
done
jq -cn --arg m "$id" --arg s "$sid" --arg t "$TEMPLATES" --arg c "$checks" \
  --argjson cr "$create_ms" --argjson b "$boot_ms" --argjson sn "$snapshot_ms" \
  '{machine:$m, snapshot:$s, templates:($t|split(" ")), checks:($c|split("\n")|map(select(length>0))), timing:{create_ms:$cr, boot_ms:$b, snapshot_ms:$sn}}'
