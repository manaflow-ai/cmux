#!/usr/bin/env bash
# End to end on a real Linux host (root, systemd as PID 1, OpenSSH): a team
# user moves work out of its sshd session scope into its systemd user manager
# (`systemd-run --user`, a `--scope` started with nohup and setsid) and turns
# lingering on, then its certificate is revoked through
# `cmux-host team-ssh apply` (bead cx-9cnf).
#
# Expected:
#   A. One session, revoked: the session, the user units and the user manager
#      all end, and lingering is off.
#   B. Two sessions on two certificates, one revoked: the revoked session ends,
#      lingering goes off, but the user manager (and the valid session's unit)
#      keeps running; revoking the second certificate then stops the manager.
#   C. Lingering turned on and logged out, no revocation: one `reap` pass turns
#      lingering off and the user manager goes away (team users never linger).
#
# Destructive for the host it runs on (a throwaway user, /etc/cmux/ssh,
# /run/cmux-host). Run it only on a throwaway Testbox or a cmuxnp-dev VM:
#   sudo bash cmux-tui/crates/cmux-host/tests/team_ssh_user_manager.sh <cmux-host binary>
set -euo pipefail

if [[ "$(id -u)" != 0 ]]; then echo "run as root" >&2; exit 2; fi
if [[ "$(ps -p 1 -o comm=)" != systemd ]]; then echo "needs systemd as PID 1" >&2; exit 2; fi
SRC_BIN="${1:?usage: team_ssh_user_manager.sh <cmux-host binary>}"

USER_NAME=cmuxt9cnf
PORT=2229
LIBEXEC=/usr/local/libexec/cmuxt9cnf
BIN="$LIBEXEC/cmux-host"
SSHD=/usr/local/sbin/sshd-cmuxt9  # its own name, so PAM uses /etc/pam.d/sshd-cmuxt9
PAM_FILE=/etc/pam.d/sshd-cmuxt9
SSH_DIR=/etc/cmux/ssh
SESSIONS=/run/cmux-host/ssh-sessions
d="$(mktemp -d)"
chmod 0755 "$d"
fails=0
sshd_unit=
SSHD_UNIT=cmuxt9cnf-sshd.service
uid=

cleanup() {
  set +e
  [[ -n "$sshd_unit" ]] && systemctl stop "$SSHD_UNIT" 2>/dev/null
  if [[ -n "$uid" ]]; then
    loginctl disable-linger "$USER_NAME" 2>/dev/null
    loginctl terminate-user "$USER_NAME" 2>/dev/null
    systemctl stop "user@$uid.service" 2>/dev/null
    sleep 1
    userdel -r "$USER_NAME" 2>/dev/null
  fi
  rm -rf "$d" "$LIBEXEC" "$SSHD" "$PAM_FILE" "$SESSIONS" "$SSH_DIR"
}
trap cleanup EXIT

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

# --- setup ---------------------------------------------------------------
install -d -m 0755 "$LIBEXEC"
install -m 0755 "$SRC_BIN" "$BIN"
install -m 0755 "$(command -v sshd)" "$SSHD"
id "$USER_NAME" >/dev/null 2>&1 && userdel -r "$USER_NAME" >/dev/null 2>&1 || true
useradd -m -s /bin/bash "$USER_NAME"
usermod -p '*' "$USER_NAME"
uid="$(id -u "$USER_NAME")"

install -d -m 0755 "$SSH_DIR" "$SSH_DIR/principals"
rm -f "$SSH_DIR/trust.json" "$SSH_DIR/revoked.krl" "$SSH_DIR/user-ca.pub"
printf '%s\n' "$USER_NAME" > "$SSH_DIR/principals/$USER_NAME"
chmod 0644 "$SSH_DIR/principals/$USER_NAME"

{ cat /etc/pam.d/sshd; echo "session required pam_exec.so quiet $BIN team-ssh session-open"; } > "$PAM_FILE"

ssh-keygen -q -t ed25519 -N "" -f "$d/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$d/ca" -C cmuxt-ca
for n in 1 2 3; do
  ssh-keygen -q -t ed25519 -N "" -f "$d/u$n"
  ssh-keygen -q -s "$d/ca" -I "cmuxt-$n" -n "$USER_NAME" -z "$n" -V +20m "$d/u$n.pub"
done
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
AllowUsers $USER_NAME
EOF

version=0
# apply <revoked key ids...>: a fresh KRL (next version) through the real trust writer.
apply() {
  version=$((version + 1))
  : > "$d/krl-spec"
  for id in "$@"; do printf 'id: %s\n' "$id" >> "$d/krl-spec"; done
  ssh-keygen -q -k -z "$version" -f "$d/krl" -s "$d/ca.pub" "$d/krl-spec"
  printf '{"generation":1,"trusted_ca_keys":["%s"],"krl":"%s","krl_version":%s}' \
    "$(cut -d' ' -f1,2 "$d/ca.pub")" "$(base64 -w0 "$d/krl")" "$version" | "$BIN" team-ssh apply
}
apply
"$SSHD" -t -f "$d/sshd_config"
# A system service like ssh.service: started from this (maybe logged-in)
# shell, pam_systemd would see an existing session and open no new one.
systemctl reset-failed "$SSHD_UNIT" 2>/dev/null || true
systemd-run --quiet --unit="$SSHD_UNIT" "$SSHD" -D -f "$d/sshd_config"
sshd_unit=1
for i in $(seq 50); do [[ -s "$d/sshd.pid" ]] && break; sleep 0.1; done

SSH=(ssh -F /dev/null -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
as() { local n="$1"; shift; "${SSH[@]}" -i "$d/u$n" -o CertificateFile="$d/u$n-cert.pub" "$USER_NAME@127.0.0.1" "$@"; }

# hold <n> <tag>: a session on certificate n that moves work out of its scope,
# turns lingering on, then waits. Prints the client pid.
hold() {
  local n="$1" tag="$2"
  as "$n" "loginctl enable-linger; \
    systemd-run --user --quiet --unit=cmuxt-$tag-svc sleep 9${n}01; \
    nohup setsid systemd-run --user --quiet --scope --unit=cmuxt-$tag-scope sleep 9${n}02 >/dev/null 2>&1 & \
    nohup setsid sleep 9${n}03 >/dev/null 2>&1 & \
    echo ready; exec sleep 600" > "$d/hold-$tag.out" 2>&1 < /dev/null &
  echo $!
  for i in $(seq 100); do grep -qs ready "$d/hold-$tag.out" && break; sleep 0.1; done
  sleep 1
}
user_procs() { ps -o args= -u "$uid" 2>/dev/null | grep -cE "^(/usr/bin/)?sleep 9$1" || true; }
manager_active() { systemctl is-active --quiet "user@$uid.service"; }
lingering() { [[ -e "/var/lib/systemd/linger/$USER_NAME" ]]; }
# wait_for <seconds> <command...>: polls until the command succeeds.
wait_for() { local s="$1"; shift; for i in $(seq $((s * 10))); do "$@" && return 0; sleep 0.1; done; return 1; }
gone() { [[ "$(user_procs "$1")" == 0 ]]; }
not() { ! "$@"; }

if [[ "$(as 3 echo ok)" == ok ]]; then pass "certificate login"; else fail "certificate login"; exit 1; fi

# --- A: one session, revoked ---------------------------------------------
echo "--- A"
client="$(hold 1 a)"
if [[ "$(user_procs 1)" == 3 ]] && manager_active && lingering; then pass "A setup: 3 escapes running, manager active, lingering"
else fail "A setup: procs=$(user_procs 1) manager=$(systemctl is-active "user@$uid.service") linger=$(lingering && echo yes || echo no) out=$(tr '\n' ';' < "$d/hold-a.out")"; fi
apply cmuxt-1
wait_for 5 not kill -0 "$client" 2>/dev/null && pass "A revoked session ended" || fail "A revoked session still open"
wait_for 5 gone 1 && pass "A no escaped process left" || fail "A escaped processes still running: $(ps -o pid=,args= -u "$uid" | tr '\n' ';')"
wait_for 5 not manager_active && pass "A user manager stopped" || fail "A user manager still $(systemctl is-active "user@$uid.service")"
not lingering && pass "A lingering off" || fail "A still lingering"

# --- B: two sessions, one revoked ----------------------------------------
echo "--- B"
c2="$(hold 2 b2)"
c3="$(hold 3 b3)"
apply cmuxt-1 cmuxt-2
wait_for 5 not kill -0 "$c2" 2>/dev/null && pass "B revoked session ended" || fail "B revoked session still open"
not lingering && pass "B lingering off after a revocation" || fail "B still lingering"
sleep 2
kill -0 "$c3" 2>/dev/null && pass "B valid session still open" || fail "B valid session ended"
manager_active && pass "B user manager kept for the valid session" || fail "B user manager stopped under a valid session"
systemctl --user -M "$USER_NAME@" is-active --quiet cmuxt-b3-svc.service && pass "B valid session's unit kept" || fail "B valid session's unit gone"
apply cmuxt-1 cmuxt-2 cmuxt-3
wait_for 5 not kill -0 "$c3" 2>/dev/null && pass "B last session ended" || fail "B last session still open"
wait_for 5 not manager_active && pass "B user manager stopped after the last valid certificate" || fail "B user manager still $(systemctl is-active "user@$uid.service")"
wait_for 5 gone 2 && wait_for 5 gone 3 && pass "B no escaped process left" || fail "B escaped processes: $(ps -o pid=,args= -u "$uid" | tr '\n' ';')"

# --- C: lingering after logout, no revocation ----------------------------
echo "--- C"
ssh-keygen -q -s "$d/ca" -I cmuxt-4 -n "$USER_NAME" -z 4 -V +20m "$d/u1.pub"
as 1 "loginctl enable-linger; systemd-run --user --quiet --unit=cmuxt-c-svc sleep 9104" < /dev/null >/dev/null 2>&1 || true
sleep 12  # past logind's UserStopDelaySec (10 s): only lingering keeps the manager now
if lingering && manager_active; then pass "C setup: lingering manager outlives the session"
else fail "C setup: linger=$(lingering && echo yes || echo no) manager=$(systemctl is-active "user@$uid.service")"; fi
"$BIN" team-ssh reap
wait_for 5 not lingering && pass "C reap turns lingering off" || fail "C still lingering after reap"
wait_for 15 not manager_active && pass "C user manager gone" || fail "C user manager still $(systemctl is-active "user@$uid.service")"
wait_for 5 gone 1 && pass "C no lingering process left" || fail "C processes: $(ps -o pid=,args= -u "$uid" | tr '\n' ';')"

# --- D: no logind session, no login --------------------------------------
# An sshd started inside an existing login session (this shell, when it is
# one) gets no logind session from pam_systemd, so nothing would scope the
# user's processes and a revocation could not end them: session-open must
# refuse such a session.
echo "--- D"
if grep -q '/session-[^/]*\.scope' /proc/self/cgroup; then
  sed -e "s/^Port .*/Port $((PORT + 1))/" -e "s|^PidFile .*|PidFile $d/sshd-d.pid|" "$d/sshd_config" > "$d/sshd_config_d"
  "$SSHD" -f "$d/sshd_config_d"
  for i in $(seq 50); do [[ -s "$d/sshd-d.pid" ]] && break; sleep 0.1; done
  ssh-keygen -q -s "$d/ca" -I cmuxt-5 -n "$USER_NAME" -z 5 -V +20m "$d/u2.pub"
  out="$("${SSH[@]}" -p "$((PORT + 1))" -i "$d/u2" -o CertificateFile="$d/u2-cert.pub" "$USER_NAME@127.0.0.1" 'echo in; nohup setsid sleep 9501 >/dev/null 2>&1 &' 2>&1 < /dev/null || true)"
  kill "$(cat "$d/sshd-d.pid")" 2>/dev/null || true
  [[ "$out" != *in* ]] && pass "D session with no logind session refused" || fail "D session with no logind session opened: $out"
  sleep 0.5
  gone 5 && pass "D nothing started" || fail "D unscoped process running: $(ps -o pid=,args= -u "$uid" | tr '\n' ';')"
else
  echo "SKIP D: this shell is not in a login session"
fi

echo "--- $fails failure(s)"
[[ "$fails" == 0 ]]
