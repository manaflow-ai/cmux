#!/usr/bin/env bash
# Live no-drop check (Leo, 2026-11-27: "ok well we should be able to just hold those messages"):
# a private acpmux daemon (own home and socket, the fake agent), N sends each racing a
# `daemon restart`; counts each message's echoes in the chat and wants exactly 1 each.
# Run: cargo build -p acpmux --bin acpmux && crates/acpmux/tests/restart_send_live.sh target/debug/acpmux 10
set -u
BIN=${1:?acpmux binary}; N=${2:-10}
H=$(mktemp -d "${TMPDIR:-/tmp}"/nodrop-live.XXXXXX)
export ACPMUX_HOME=$H ACPMUX_SOCKET=$H/s.sock
FAKE=$(cd "$(dirname "$0")" && pwd)/fake_agent.py
cat > "$H/config.json" <<CFG
{"defaultHarness": "fake", "permissionPolicy": "approve-all",
 "harnesses": {"fake": {"argv": ["python3", "$FAKE"]}}}
CFG
env -u ACPMUX_SESSION_ID -u ACPMUX_CALLER_TOKEN "$BIN" daemon run > "$H/daemon.log" 2>&1 &
echo "daemon pid $!"
for i in $(seq 50); do "$BIN" daemon status >/dev/null 2>&1 && break; sleep 0.2; done
"$BIN" new hold-lane -d --cwd "$H" > "$H/new.out" 2>&1 || { echo "new failed"; cat "$H/new.out" "$H/daemon.log"; exit 1; }
ok=0; bad=0
for i in $(seq "$N"); do
  msg="hold-live-$i-$RANDOM"
  ( "$BIN" send hold-lane "$msg" --no-wait > "$H/send-$i.out" 2>&1; echo $? > "$H/send-$i.rc" ) &
  sp=$!
  sleep 0.0$((RANDOM % 9))
  "$BIN" daemon restart > "$H/restart-$i.out" 2>&1
  wait $sp
  for t in $(seq 60); do c=$("$BIN" last hold-lane -n 100 2>/dev/null | grep -c "$msg"); [ "${c:-0}" -ge 1 ] && break; sleep 0.5; done
  sleep 1; c=$("$BIN" last hold-lane -n 100 2>/dev/null | grep -o "$msg" | wc -l)
  echo "send $i rc=$(cat $H/send-$i.rc) replies=$c"
  if [ "$c" -eq 1 ]; then ok=$((ok+1)); else bad=$((bad+1)); cat "$H/send-$i.out"; fi
done
echo "RESULT exactly_once=$ok of $N wrong=$bad"
"$BIN" daemon shutdown >/dev/null 2>&1
[ "$bad" -eq 0 ]
