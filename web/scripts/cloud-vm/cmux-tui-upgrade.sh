#!/bin/sh
# Upgrades a running machine's cmux-tui in place without ending a terminal.
# docs/cloud-guest-upgrades.md is the contract this relies on; the fleet
# runner (web/scripts/upgrade-fleet-cmux-tui.ts) writes this file and the
# pinned install command into a fresh run directory and runs it detached as
# root, so a provider exec timeout cannot interrupt it midway.
#
# Terminals survive because each one lives in its own `__terminal-host`
# process: SIGTERM ends only the daemon, cmux-devbox-boot restarts it from the
# new binary within a second, and the new daemon adopts the live hosts. A
# crash-looping daemon is handled by a bounded canary: the old binary is
# checksummed into the run directory, the published binary is staged and
# checksummed, and only the daemon child is stopped. The supervisor is never
# restarted as a control group, and terminal hosts are never killed.
#
# Usage: cmux-tui-upgrade.sh <target-sha256> <target-commit> <run-dir> [state-mount]
# <run-dir> holds install.cmd (the pinned install command) and receives
# `result` (one line: OK, UNVERIFIED, SKIP, PENDING, ROLLBACK or FAIL), `log`, and the
# replaced binary. One run at a time per machine: a second run reports SKIP busy.
set -u
TARGET_SHA=${1:?target sha256}
TARGET_COMMIT=${2:?target commit}
RUN=${3:?run dir}
STATE_MOUNT=${4:-/usr/local/bin/cmux-tui-state-mount}
OUT="$RUN/result"
say() { echo "$(date -u +%FT%TZ) $*" >> "$RUN/log"; }
finish() { echo "$1" > "$OUT"; say "RESULT $1"; exit 0; }
echo running > "$OUT"
exec 9> "$(dirname "$RUN")/lock"
flock -n 9 || finish "SKIP busy another upgrade run holds the lock"

daemon_pid() { pgrep -f "cmux-tui server start --session cloud" | head -1; }
host_pids() { ps -eo pid=,args= | awk '$2 ~ /(cmux-tui|\/proc\/self\/exe)$/ && $3=="__terminal-host"{print $1}' | sort -n | tr '\n' ' '; }
term_count() { if [ "$H" = /root ]; then U=root; else U=cmux; fi; sudo -n -u "$U" env HOME="$H" "$BIN" --session cloud --json terminal list 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); print(len(d if isinstance(d,list) else (d.get("terminals") or [])))' 2>/dev/null || echo "?"; }
exe_sha() { sha256sum "/proc/$1/exe" 2>/dev/null | cut -d' ' -f1; }
bin_sha() { sha256sum "$BIN" 2>/dev/null | cut -d' ' -f1; }
listening() { ss -ltnH 2>/dev/null | grep -q ':1337 '; }
healthy() {
  listening || return 1
  timeout --signal=TERM --kill-after=1s 10s \
    sudo -n -u "$( [ "$H" = /root ] && echo root || echo cmux )" \
    env HOME="$H" "$BIN" server status --session cloud >/dev/null 2>&1
}
state_mount_user() { [ "$H" = /root ] && echo root || echo cmux; }
STATE_MOUNT_UPDATED=0
STATE_MOUNT_PREV="$RUN/cmux-tui-state-mount.prev"
install_state_mount() {
  [ -f "$RUN/state-mount.sh" ] || return 0
  sh -n "$RUN/state-mount.sh" || finish "FAIL state-mount-syntax"
  if [ -f "$STATE_MOUNT" ]; then
    cp -p "$STATE_MOUNT" "$STATE_MOUNT_PREV" || finish "FAIL state-mount-backup"
  fi
  install -m 0755 "$RUN/state-mount.sh" "$STATE_MOUNT" || finish "FAIL state-mount-install"
  STATE_MOUNT_UPDATED=1
  "$STATE_MOUNT" ensure "$H" "$(state_mount_user)" || finish "FAIL state-reservation-unavailable"
}
restore_state_mount() {
  [ "$STATE_MOUNT_UPDATED" = 1 ] || return 0
  if [ -f "$STATE_MOUNT_PREV" ]; then
    install -m 0755 "$STATE_MOUNT_PREV" "$STATE_MOUNT"
  else
    rm -f "$STATE_MOUNT"
  fi
}
# A daemon replays its journal and adopts every live host before it listens,
# which takes minutes on a large journal, and it defers SIGTERM until then.
wait_listener() { i=0; while [ $i -lt 600 ]; do listening && return 0; sleep 1; i=$((i+1)); done; return 1; }
# Waits for a daemon running <sha> to listen and stay up; prints its pid.
wait_serving() {
  N=""; i=0
  while [ $i -lt 30 ]; do N=$(daemon_pid); [ -n "$N" ] && [ "$(exe_sha "$N")" = "$1" ] && break; N=""; sleep 1; i=$((i+1)); done
  [ -n "$N" ] || return 1
  i=0; while [ $i -lt 600 ]; do
    [ "$(daemon_pid)" = "$N" ] || return 1
    if healthy; then [ "$(daemon_pid)" = "$N" ] && echo "$N" && return 0; return 1; fi
    sleep 1; i=$((i+1))
  done
  return 1
}

stop_child() {
  [ -n "${1:-}" ] || return 0
  kill -TERM "$1" 2>/dev/null || true
  i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL "$1" 2>/dev/null || true
}

canary_crash_loop() {
  D=$(daemon_pid)
  [ -n "$D" ] || finish "SKIP no-daemon"
  tr '\0' ' ' < "/proc/$D/cmdline" | grep -q -- --remote-ws-trusted-carrier || finish "SKIP no-trusted-carrier"
  canary_fail() { restore_state_mount; finish "$1"; }
  OLD_SHA=$(bin_sha)
  HOSTS_BEFORE=$(host_pids)
  [ -n "$OLD_SHA" ] || canary_fail "FAIL canary-old-binary-unreadable"
  cp -p "$BIN" "$RUN/cmux-tui.prev" || canary_fail "FAIL canary-backup-copy"
  [ "$(sha256sum "$RUN/cmux-tui.prev" | cut -d' ' -f1)" = "$OLD_SHA" ] || canary_fail "FAIL canary-backup-checksum"
  say "canary before old=$OLD_SHA target=$TARGET_COMMIT hosts=[$HOSTS_BEFORE]"
  stop_child "$D"
  if ! sh "$RUN/install.cmd" >> "$RUN/log" 2>&1; then
    [ "$(bin_sha)" = "$TARGET_SHA" ] || canary_fail "FAIL canary-install"
  fi
  [ "$(bin_sha)" = "$TARGET_SHA" ] || canary_fail "FAIL canary-pin-mismatch"
  say "canary staged target=$TARGET_SHA"
  if N=$(wait_serving "$TARGET_SHA"); then
    LOST=""; for p in $HOSTS_BEFORE; do kill -0 "$p" 2>/dev/null || LOST="$LOST $p"; done
    [ -z "$LOST" ] || canary_fail "FAIL canary-lost-hosts=[${LOST# }] daemon=$N"
    finish "OK canary daemon=$N hosts-before=$(echo $HOSTS_BEFORE | wc -w)"
  fi
  cp -p "$RUN/cmux-tui.prev" "$BIN.rollback" && mv -f "$BIN.rollback" "$BIN" || canary_fail "FAIL canary-rollback-copy"
  [ "$(bin_sha)" = "$OLD_SHA" ] || canary_fail "FAIL canary-rollback-checksum"
  X=$(daemon_pid); [ -n "$X" ] && stop_child "$X"
  if N=$(wait_serving "$OLD_SHA"); then
    restore_state_mount
    finish "ROLLBACK canary-target-unhealthy old-daemon=$N"
  fi
  canary_fail "FAIL canary-target-and-rollback-unhealthy inspect=$RUN/log"
}

if id -u cmux >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && setpriv --reuid=cmux --regid=cmux --init-groups test -w /home/cmux 2>/dev/null && setpriv --reuid=cmux --regid=cmux --init-groups sudo -n true >/dev/null 2>&1; then H=/home/cmux; else H=/root; fi
BIN="$H/.cmux/bin/cmux-tui"
install_state_mount
# A crash-looping daemon is between restarts most of the time.
D=""; i=0; while [ -z "$D" ] && [ $i -lt 10 ]; do D=$(daemon_pid); [ -n "$D" ] || sleep 0.5; i=$((i+1)); done
[ -n "$D" ] || { canary_crash_loop; }
tr '\0' ' ' < /proc/$D/cmdline | grep -q -- --remote-ws-trusted-carrier || finish "SKIP no-trusted-carrier"
if [ "$(exe_sha "$D")" = "$TARGET_SHA" ]; then
  # The next restart runs the binary on disk, so it must match too.
  [ "$(bin_sha)" = "$TARGET_SHA" ] || sh "$RUN/install.cmd" >> "$RUN/log" 2>&1
  [ "$(bin_sha)" = "$TARGET_SHA" ] && finish "OK already-current daemon=$D" || finish "FAIL daemon-current-but-binary-not"
fi
if ! wait_listener; then
  canary_crash_loop
fi
FREE=$(df -Pm "$H" | awk 'NR==2{print $4}')
[ "$FREE" -ge 300 ] || finish "SKIP disk-free=${FREE}MB"
HOSTS_BEFORE=$(host_pids)
TERMS_BEFORE=$(term_count)
OLD_SHA=$(bin_sha)
say "before daemon=$D old=$OLD_SHA target=$TARGET_COMMIT hosts=[$HOSTS_BEFORE] terminals=$TERMS_BEFORE free=${FREE}MB"
cp -p "$BIN" "$RUN/cmux-tui.prev" && [ "$(sha256sum "$RUN/cmux-tui.prev" | cut -d' ' -f1)" = "$OLD_SHA" ] || finish "FAIL backup (nothing changed)"
if ! sh "$RUN/install.cmd" >> "$RUN/log" 2>&1; then
  # The binary step runs first; a hook-step failure leaves the pinned binary, which is still correct.
  [ "$(bin_sha)" = "$TARGET_SHA" ] || finish "FAIL install (binary not replaced)"
  say "install: hook step failed, binary is pinned; continuing"
fi
[ "$(bin_sha)" = "$TARGET_SHA" ] || finish "FAIL pin-mismatch"
D=$(daemon_pid)
stop_child "$D"

if N=$(wait_serving "$TARGET_SHA"); then
  LOST=""; for p in $HOSTS_BEFORE; do kill -0 "$p" 2>/dev/null || LOST="$LOST $p"; done
  TERMS_AFTER=$(term_count)
  [ -z "$LOST" ] || finish "FAIL lost-hosts=[${LOST# }] terminals=$TERMS_BEFORE->$TERMS_AFTER daemon=$N"
  # Every host survived, but without both counts the terminals are not proven.
  case "$TERMS_BEFORE$TERMS_AFTER" in *'?'*) finish "UNVERIFIED terminal count unavailable terminals=$TERMS_BEFORE->$TERMS_AFTER daemon=$N" ;; esac
  [ "$TERMS_AFTER" -ge "$TERMS_BEFORE" ] || finish "FAIL terminals=$TERMS_BEFORE->$TERMS_AFTER daemon=$N"
  finish "OK upgraded terminals=$TERMS_BEFORE->$TERMS_AFTER daemon=$N hosts-before=$(echo $HOSTS_BEFORE | wc -w)"
fi

# The new daemon crashed or never listened. It may already have migrated the
# on-disk state, so a restored old binary is only trusted once it serves again.
say "new daemon did not serve; restoring $OLD_SHA"
restore_state_mount
cp -p "$RUN/cmux-tui.prev" "$BIN.rollback" && mv -f "$BIN.rollback" "$BIN" && [ "$(bin_sha)" = "$OLD_SHA" ] \
  || finish "FAIL rollback-restore (target binary may remain; inspect $RUN/log)"
X=$(daemon_pid); [ -n "$X" ] && stop_child "$X"
N=$(wait_serving "$OLD_SHA") \
  || finish "FAIL rollback-daemon-unhealthy (old binary restored but does not serve; on-disk state may be migrated)"
finish "ROLLBACK new-daemon-unstable; old daemon serving daemon=$N"
