#!/bin/sh
# Upgrades a running machine's cmux-tui in place without ending a terminal.
# docs/cloud-guest-upgrades.md is the contract this relies on; the fleet
# runner (web/scripts/upgrade-fleet-cmux-tui.ts) writes this file and the
# pinned install command into /var/lib/cmux-tui-upgrade and runs it detached
# as root, so a provider exec timeout cannot interrupt it midway.
#
# Terminals survive because each one lives in its own `__terminal-host`
# process: SIGTERM ends only the daemon, cmux-devbox-boot restarts it from the
# new binary within a second, and the new daemon adopts the live hosts. The
# script refuses (SKIP) instead of guessing when a machine's supervisor would
# not restart the daemon with the current contract, and rolls the binary back
# when the new daemon crashes or never listens.
#
# Usage: cmux-tui-upgrade.sh <target-sha256> <target-commit>
# Result: one line in /var/lib/cmux-tui-upgrade/result, starting with
# OK, SKIP, PENDING, ROLLBACK or FAIL. Log: /var/lib/cmux-tui-upgrade/log.
set -u
TARGET_SHA=${1:?target sha256}
TARGET_COMMIT=${2:?target commit}
OUT=/var/lib/cmux-tui-upgrade/result
mkdir -p /var/lib/cmux-tui-upgrade
say() { echo "$(date -u +%FT%TZ) $*" >> /var/lib/cmux-tui-upgrade/log; }
finish() { echo "$1" > "$OUT"; say "RESULT $1"; exit 0; }
daemon_pid() { pgrep -f "cmux-tui server start --session cloud" | head -1; }
host_pids() { ps -eo pid=,args= | awk '$2 ~ /(cmux-tui|\/proc\/self\/exe)$/ && $3=="__terminal-host"{print $1}' | sort -n | tr '\n' ' '; }
term_count() { if [ "$H" = /root ]; then U=root; else U=cmux; fi; sudo -n -u "$U" env HOME="$H" "$BIN" --session cloud --json terminal list 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); print(len(d if isinstance(d,list) else (d.get("terminals") or [])))' 2>/dev/null || echo "?"; }
exe_sha() { sha256sum "/proc/$1/exe" 2>/dev/null | cut -d' ' -f1; }
bin_sha() { sha256sum "$BIN" 2>/dev/null | cut -d' ' -f1; }
# A daemon that is still starting (it adopts every live host first, minutes on
# a large journal) defers SIGTERM until it is ready, so wait for its listener.
wait_listener() { i=0; while [ $i -lt 600 ] && ! ss -ltnH 2>/dev/null | grep -q ':1337 '; do sleep 1; i=$((i+1)); done; }
echo running > "$OUT"
if id -u cmux >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && setpriv --reuid=cmux --regid=cmux --init-groups test -w /home/cmux 2>/dev/null && setpriv --reuid=cmux --regid=cmux --init-groups sudo -n true >/dev/null 2>&1; then H=/home/cmux; else H=/root; fi
BIN="$H/.cmux/bin/cmux-tui"
# A crash-looping daemon is between restarts most of the time.
D=""; i=0; while [ -z "$D" ] && [ $i -lt 10 ]; do D=$(daemon_pid); [ -n "$D" ] || sleep 0.5; i=$((i+1)); done
[ -n "$D" ] || finish "SKIP no-daemon"
tr '\0' ' ' < /proc/$D/cmdline | grep -q -- --remote-ws-trusted-carrier || finish "SKIP no-trusted-carrier"
if [ "$(exe_sha "$D")" = "$TARGET_SHA" ]; then
  # The next restart runs the binary on disk, so it must match too.
  [ "$(bin_sha)" = "$TARGET_SHA" ] || sh /var/lib/cmux-tui-upgrade/install.cmd >> /var/lib/cmux-tui-upgrade/log 2>&1
  [ "$(bin_sha)" = "$TARGET_SHA" ] && finish "OK already-current daemon=$D" || finish "FAIL daemon-current-but-binary-not"
fi
FREE=$(df -Pm "$H" | awk 'NR==2{print $4}')
[ "$FREE" -ge 300 ] || finish "SKIP disk-free=${FREE}MB"
HOSTS_BEFORE=$(host_pids)
TERMS_BEFORE=$(term_count)
OLD_SHA=$(sha256sum "$BIN" | cut -d' ' -f1)
say "before daemon=$D old=$OLD_SHA hosts=[$HOSTS_BEFORE] terminals=$TERMS_BEFORE free=${FREE}MB"
[ -e "$BIN.pre-$TARGET_COMMIT" ] || cp -p "$BIN" "$BIN.pre-$TARGET_COMMIT" || finish "FAIL backup"
if ! sh /var/lib/cmux-tui-upgrade/install.cmd >> /var/lib/cmux-tui-upgrade/log 2>&1; then
  # The binary step runs first; a hook-step failure leaves the pinned binary, which is still correct.
  [ "$(sha256sum "$BIN" | cut -d' ' -f1)" = "$TARGET_SHA" ] || finish "FAIL install (old binary untouched)"
  say "install: hook step failed, binary is pinned; continuing"
fi
[ "$(sha256sum "$BIN" | cut -d' ' -f1)" = "$TARGET_SHA" ] || finish "FAIL pin-mismatch"
wait_listener
D=$(daemon_pid)
kill -TERM "$D"
i=0; while kill -0 "$D" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
kill -0 "$D" 2>/dev/null && finish "PENDING old-daemon-ignored-TERM daemon=$D (new binary installed, applies on next restart)"
N=""; i=0
while [ $i -lt 30 ]; do N=$(daemon_pid); [ -n "$N" ] && [ "$(exe_sha "$N")" = "$TARGET_SHA" ] && break; N=""; sleep 1; i=$((i+1)); done
# Startup adopts every live terminal host and can take a minute on a busy
# machine; judge only a crash (pid change) or no listener after 180 s.
STABLE=""
if [ -n "$N" ]; then
  i=0; while [ $i -lt 600 ]; do
    [ "$(daemon_pid)" = "$N" ] || break
    if ss -ltnH 2>/dev/null | grep -q ':1337 '; then sleep 5; [ "$(daemon_pid)" = "$N" ] && STABLE=1; break; fi
    sleep 1; i=$((i+1))
  done
fi
LOST=""; for p in $HOSTS_BEFORE; do kill -0 "$p" 2>/dev/null || LOST="$LOST $p"; done
if [ -z "$STABLE" ]; then
  say "new daemon not stable (pid=${N:-none}); rolling back"
  cp -p "$BIN.pre-$TARGET_COMMIT" "$BIN.rollback" && mv -f "$BIN.rollback" "$BIN"
  wait_listener
  X=$(daemon_pid); [ -n "$X" ] && kill -TERM "$X"
  finish "ROLLBACK new-daemon-unstable lost-hosts=[${LOST# }]"
fi
TERMS_AFTER=$(term_count)
finish "OK upgraded terminals=$TERMS_BEFORE->$TERMS_AFTER daemon=$N hosts-before=$(echo $HOSTS_BEFORE | wc -w) lost-hosts=[${LOST# }]"
