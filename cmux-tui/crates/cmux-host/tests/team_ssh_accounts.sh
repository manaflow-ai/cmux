#!/usr/bin/env bash
# End to end on a real Linux host (root, systemd as PID 1, OpenSSH): the team
# VM account reconciler (team-vm-plan.md S4, bead cx-embr) and the agent
# force-command `cmux team restricted-shell` (S5, decision D28).
#
# `cmux-host team-ssh accounts-apply` takes a `team_vm.accounts` value on
# stdin, the same shape the 30 s trust sync reads as the VM's install.
#
# Expected:
#   A. Before any accounts apply, no team user exists and a team certificate
#      cannot log in.
#   B. After the apply: each user exists with the UID the team allocated, is
#      in the sshd login group, and has a principals file. A person's
#      certificate gets a shell; an agent certificate runs only allowlisted
#      `cmux team …` verbs (no shell, no systemd-run, no other cmux verbs).
#   C. A second apply with the same view changes nothing; a tampered
#      principals file is put back.
#   D. A name that exists with another UID, or a UID another user holds, is
#      refused and gets no principals file.
#   E. A member removed from the view: the principals file goes, the open
#      session ends, a new login is refused, and the Linux user (and its UID)
#      stays.
#
# Destructive for the host it runs on (throwaway users, /etc/cmux/ssh,
# /run/cmux-host). Run it only on a throwaway Testbox or a cmuxnp-dev VM:
#   sudo bash cmux-tui/crates/cmux-host/tests/team_ssh_accounts.sh <cmux-host binary>
set -euo pipefail

if [[ "$(id -u)" != 0 ]]; then echo "run as root" >&2; exit 2; fi
if [[ "$(ps -p 1 -o comm=)" != systemd ]]; then echo "needs systemd as PID 1" >&2; exit 2; fi
SRC_BIN="${1:?usage: team_ssh_accounts.sh <cmux-host binary>}"

PORT=2239
LIBEXEC=/usr/local/libexec/cmuxtembr
BIN="$LIBEXEC/cmux-host"
SSHD=/usr/local/sbin/sshd-cmuxtembr  # its own name, so PAM uses /etc/pam.d/sshd-cmuxtembr
PAM_FILE=/etc/pam.d/sshd-cmuxtembr
SSHD_UNIT=cmuxtembr-sshd.service
SSH_DIR=/etc/cmux/ssh
SESSIONS=/run/cmux-host/ssh-sessions
LOGIN_GROUP=cmux-ssh
TEAM_USERS=(cmuxtalice cmuxtalice-agents cmuxtbob cmuxtbob-agents cmuxtsys cmuxtcarol cmuxtother)
d="$(mktemp -d)"
chmod 0755 "$d"
fails=0
sshd_unit=

cleanup() {
  set +e
  [[ -n "$sshd_unit" ]] && systemctl stop "$SSHD_UNIT" 2>/dev/null
  for u in "${TEAM_USERS[@]}"; do
    if id "$u" >/dev/null 2>&1; then
      loginctl terminate-user "$u" 2>/dev/null
      systemctl stop "user@$(id -u "$u").service" 2>/dev/null
      # userdel refuses while the user still has processes (the user manager stops asynchronously).
      for i in $(seq 50); do userdel -r "$u" 2>/dev/null && break; sleep 0.1; done
    fi
    getent group "$u" >/dev/null && groupdel "$u" 2>/dev/null
  done
  getent group "$LOGIN_GROUP" >/dev/null && groupdel "$LOGIN_GROUP" 2>/dev/null
  rm -rf "$d" "$LIBEXEC" "$SSHD" "$PAM_FILE" "$SESSIONS" "$SSH_DIR"
}
trap cleanup EXIT

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
wait_for() { local s="$1"; shift; for i in $(seq $((s * 10))); do "$@" && return 0; sleep 0.1; done; return 1; }
not() { ! "$@"; }

# --- setup ---------------------------------------------------------------
for u in "${TEAM_USERS[@]}"; do
  if id "$u" >/dev/null 2>&1; then echo "user $u already exists; not a throwaway host" >&2; exit 2; fi
done
for uid in 20000 20002 20004 20006 20008 20010; do
  if getent passwd "$uid" >/dev/null; then echo "uid $uid is taken; not a throwaway host" >&2; exit 2; fi
done
install -d -m 0755 "$LIBEXEC"
install -m 0755 "$SRC_BIN" "$BIN"
install -m 0755 "$(command -v sshd)" "$SSHD"
# The image bakes the login group (web/scripts/cmux-vm-image/sshd.ts).
groupadd --system "$LOGIN_GROUP"
# A name the team never allocated to this UID (the reconciler must not take it).
useradd --system --no-create-home --shell /usr/sbin/nologin cmuxtsys
# A local user that holds a UID in the team range (the reconciler must not reuse it).
useradd --uid 20010 --no-create-home --shell /usr/sbin/nologin cmuxtother

install -d -m 0755 "$SSH_DIR" "$SSH_DIR/principals"
rm -f "$SSH_DIR/trust.json" "$SSH_DIR/revoked.krl" "$SSH_DIR/user-ca.pub" "$SSH_DIR/accounts.json"
{ cat /etc/pam.d/sshd; echo "session required pam_exec.so quiet $BIN team-ssh session-open"; } > "$PAM_FILE"

ssh-keygen -q -t ed25519 -N "" -f "$d/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$d/ca" -C cmuxt-ca
# cert <file> <key id> <principal> <serial> [force-command]
cert() {
  ssh-keygen -q -t ed25519 -N "" -f "$d/$1"
  if [[ -n "${5:-}" ]]; then
    ssh-keygen -q -s "$d/ca" -I "$2" -n "$3" -z "$4" -V +20m -O clear -O "force-command=$5" "$d/$1.pub"
  else
    ssh-keygen -q -s "$d/ca" -I "$2" -n "$3" -z "$4" -V +20m "$d/$1.pub"
  fi
}
cert alice embr-alice cmuxtalice 1
cert alice2 embr-alice2 cmuxtalice 2
cert agent embr-agent cmuxtalice-agents 3 "$BIN team restricted-shell"
cert bob embr-bob cmuxtbob 4
cert sys embr-sys cmuxtsys 5
cert carol embr-carol cmuxtcarol 6

cat > "$d/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $d/hostkey
PidFile $d/sshd.pid
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile none
TrustedUserCAKeys $SSH_DIR/user-ca.pub
AuthorizedPrincipalsFile none
AuthorizedPrincipalsCommand $BIN team-ssh principals %u
AuthorizedPrincipalsCommandUser nobody
RevokedKeys $SSH_DIR/revoked.krl
UsePAM yes
AllowGroups $LOGIN_GROUP
EOF

ssh-keygen -q -k -z 1 -f "$d/krl"
printf '{"generation":1,"trusted_ca_keys":["%s"],"krl":"%s","krl_version":1}' \
  "$(cut -d' ' -f1,2 "$d/ca.pub")" "$(base64 -w0 "$d/krl")" | "$BIN" team-ssh apply >/dev/null
"$SSHD" -t -f "$d/sshd_config"
systemctl reset-failed "$SSHD_UNIT" 2>/dev/null || true
systemd-run --quiet --unit="$SSHD_UNIT" "$SSHD" -D -f "$d/sshd_config"
sshd_unit=1
wait_for 5 test -s "$d/sshd.pid" || { fail "setup: sshd did not start"; exit 1; }

SSH=(ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -p "$PORT")
# as <cert file> <user> <command...>
as() { local c="$1" u="$2"; shift 2; "${SSH[@]}" -i "$d/$c" -o CertificateFile="$d/$c-cert.pub" "$u@127.0.0.1" "$@" < /dev/null 2>&1; }

# entry <user> <uid> <class>
entry() { printf '{"user":"%s","uid":%s,"class":"%s","principals":["%s"]}' "$1" "$2" "$3" "$1"; }
view() { local IFS=,; printf '{"team":"team_embr","users":[%s]}' "$*"; }
ALICE="$(entry cmuxtalice 20000 human),$(entry cmuxtalice-agents 20002 agent)"
BOB="$(entry cmuxtbob 20004 human),$(entry cmuxtbob-agents 20006 agent)"
accounts() { printf '%s' "$1" | "$BIN" team-ssh accounts-apply; }

# --- A: nothing before the first apply -----------------------------------
echo "--- A"
id cmuxtalice >/dev/null 2>&1 && fail "A cmuxtalice exists before the apply" || pass "A no team user before the apply"
out="$(as alice cmuxtalice echo opened || true)"
[[ "$out" != *opened* ]] && pass "A team certificate refused before the apply" || fail "A login before the apply: $out"

# --- B: apply creates users, groups and principals -----------------------
echo "--- B"
out="$(accounts "$(view "$ALICE" "$BOB")")" || fail "B apply exit $?: $out"
echo "B apply: $out"
for pair in cmuxtalice:20000 cmuxtalice-agents:20002 cmuxtbob:20004 cmuxtbob-agents:20006; do
  u="${pair%%:*}" want="${pair#*:}"
  if [[ "$(id -u "$u" 2>/dev/null)" == "$want" && "$(id -g "$u")" == "$want" ]]; then pass "B $u has uid and gid $want"; else fail "B $u: $(id "$u" 2>&1)"; fi
  id -nG "$u" | tr ' ' '\n' | grep -qx "$LOGIN_GROUP" && pass "B $u is in $LOGIN_GROUP" || fail "B $u not in $LOGIN_GROUP: $(id -nG "$u")"
  [[ "$(cat "$SSH_DIR/principals/$u" 2>/dev/null)" == "$u" ]] && pass "B $u principals file" || fail "B $u principals: $(cat "$SSH_DIR/principals/$u" 2>&1)"
  [[ "$(getent shadow "$u" | cut -d: -f2)" == '!'* ]] && pass "B $u password locked" || fail "B $u password not locked"
done
[[ "$(getent passwd cmuxtalice-agents | cut -d: -f7)" == /bin/sh ]] && pass "B agent user shell is /bin/sh" || fail "B agent shell: $(getent passwd cmuxtalice-agents)"
[[ "$(as alice cmuxtalice id -u)" == 20000 ]] && pass "B person certificate gets a shell as cmuxtalice" || fail "B person login: $(as alice cmuxtalice id -u)"
out="$(as agent cmuxtalice-agents cmux team whoami)"
[[ "$out" == "cmuxtalice-agents 20002" ]] && pass "B agent runs cmux team whoami" || fail "B agent whoami: $out"
out="$(as agent cmuxtalice-agents "$BIN" team whoami)"
[[ "$out" == "cmuxtalice-agents 20002" ]] && pass "B agent runs the absolute cmux path" || fail "B agent absolute whoami: $out"
for cmd in "" "id" "bash -c id" "sh" "systemd-run --user sleep 1" "at now" "crontab -l" "cmux host team-ssh reap" \
  "cmux team restricted-shell" "cmux team whoami; id" "cmux team whoami && id" 'cmux team whoami $(id)' "cmux team whoami extra" \
  "cmux team nosuchverb" "cmux team" "/bin/cmux team whoami" "cmux 'team whoami'"; do
  out="$(as agent cmuxtalice-agents "$cmd" || true)"
  if [[ "$out" == *"restricted-shell:"* && "$out" != *"uid="* && "$out" != *"20002"* ]]; then pass "B agent refused: [$cmd]"; else fail "B agent ran [$cmd]: $out"; fi
done
out="$(as agent cmuxtalice-agents "cmux 'team' \"whoami\"")"
[[ "$out" == "cmuxtalice-agents 20002" ]] && pass "B quoted words are words, not shell" || fail "B quoted whoami: $out"
out="$(as sys cmuxtsys echo opened || true)"
[[ "$out" != *opened* ]] && pass "B a user outside the team view cannot log in" || fail "B cmuxtsys logged in: $out"

# --- C: idempotent, drift reverted ---------------------------------------
echo "--- C"
out="$(accounts "$(view "$ALICE" "$BOB")")"
[[ "$out" == *'"created":[]'* && "$out" == *'"written":[]'* && "$out" == *'"removed":[]'* ]] && pass "C second apply is a no-op" || fail "C second apply: $out"
printf 'root\n' > "$SSH_DIR/principals/cmuxtbob"
out="$(accounts "$(view "$ALICE" "$BOB")")"
[[ "$(cat "$SSH_DIR/principals/cmuxtbob")" == cmuxtbob && "$out" == *'"written":["cmuxtbob"]'* ]] && pass "C tampered principals file put back" || fail "C drift: $(cat "$SSH_DIR/principals/cmuxtbob") $out"

# --- D: refusals ----------------------------------------------------------
echo "--- D"
out="$(accounts "$(view "$ALICE" "$BOB" "$(entry cmuxtsys 20008 human)" "$(entry cmuxtcarol 20010 human)")" || true)"
echo "D apply: $out"
[[ ! -e "$SSH_DIR/principals/cmuxtsys" && "$(id -u cmuxtsys)" -lt 1000 ]] && pass "D an existing system name is not taken over" || fail "D cmuxtsys: $(id cmuxtsys) $(ls "$SSH_DIR/principals")"
[[ "$out" == *cmuxtsys* && "$out" == *refused* ]] && pass "D the system name is reported" || fail "D cmuxtsys not reported: $out"
not id cmuxtcarol >/dev/null 2>&1 && [[ ! -e "$SSH_DIR/principals/cmuxtcarol" ]] && pass "D a UID another user holds is refused" || fail "D cmuxtcarol: $(id cmuxtcarol 2>&1)"
[[ "$out" == *"cmuxtcarol: uid 20010 belongs to cmuxtother"* ]] && pass "D the UID clash is reported" || fail "D cmuxtcarol not reported: $out"
[[ "$(cat "$SSH_DIR/principals/cmuxtalice")" == cmuxtalice ]] && pass "D a refusal leaves the other users alone" || fail "D cmuxtalice principals changed"

# --- E: a removed member ---------------------------------------------------
echo "--- E"
as alice2 cmuxtalice 'echo ready; exec sleep 600' > "$d/hold.out" 2>&1 &
client=$!
wait_for 10 grep -qs ready "$d/hold.out" || fail "E setup: held session did not open: $(cat "$d/hold.out")"
wait_for 5 grep -qs embr-alice2 "$SESSIONS"/*.json || fail "E setup: session not recorded"
out="$(accounts "$(view "$BOB")")"
echo "E apply: $out"
[[ ! -e "$SSH_DIR/principals/cmuxtalice" && ! -e "$SSH_DIR/principals/cmuxtalice-agents" ]] && pass "E principals of the removed member are gone" || fail "E principals left: $(ls "$SSH_DIR/principals")"
wait_for 10 not kill -0 "$client" 2>/dev/null && pass "E the removed member's open session ended" || fail "E session still open"
out="$(as alice cmuxtalice echo opened || true)"
[[ "$out" != *opened* ]] && pass "E the removed member cannot log in" || fail "E removed member logged in: $out"
out="$(as agent cmuxtalice-agents cmux team whoami || true)"
[[ "$out" != *20002* ]] && pass "E the removed member's agents cannot log in" || fail "E removed agents logged in: $out"
[[ "$(id -u cmuxtalice)" == 20000 ]] && pass "E the Linux user and its UID stay" || fail "E cmuxtalice: $(id cmuxtalice 2>&1)"
[[ "$(as bob cmuxtbob id -u)" == 20004 ]] && pass "E the remaining member still logs in" || fail "E bob login"
out="$(accounts "$(view "$ALICE" "$BOB")")"
[[ "$(as alice cmuxtalice id -u)" == 20000 ]] && pass "E a member added back gets the same user" || fail "E re-add: $out"

echo "--- $fails failure(s)"
[[ "$fails" == 0 ]]
