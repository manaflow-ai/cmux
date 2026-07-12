#!/bin/bash
# Long unattended run of the live layout fuzz: many seeds, evidence capture,
# automatic recovery. Every failure or hang leaves enough on disk to
# reproduce and diagnose it: the seed and iteration, the fuzz log, the app's
# debug log tail, and — for hangs — a process sample taken while stuck.
#
# Usage: CMUX_TAG=main scripts/remote-tmux-fuzz-marathon.sh <ssh-host> [seeds] [iters-per-seed]
# Output: /tmp/cmux-fuzz-marathon/<start-time>/
set -u

HOST="${1:?usage: CMUX_TAG=<tag> $0 <ssh-host> [seeds] [iters]}"
SEEDS="${2:-40}"
ITERS="${3:-25}"
: "${CMUX_TAG:?CMUX_TAG is required}"
APP="${CMUX_FUZZ_APP:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${CMUX_TAG}/Build/Products/Debug/cmux DEV ${CMUX_TAG}.app}"
DEBUG_LOG="/tmp/cmux-debug-${CMUX_TAG}.log"
# Exactly one driver. Concurrent marathons share one app and one tmux lab,
# and each seed's setup kills the lab server — yanking layouts out from
# under the other run's iterations and manufacturing failures no code
# produced. A stale pid file (dead owner) is taken over silently.
LOCK=/tmp/cmux-fuzz-marathon.pid
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "another marathon (pid $(cat "$LOCK")) is running — refusing to start a second"
  exit 96
fi
echo $$ > "$LOCK"

DIR="/tmp/cmux-fuzz-marathon/$(date +%Y%m%d-%H%M%S)"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR"
echo "marathon: $SEEDS seeds x $ITERS iters -> $DIR"

app_pid() { pgrep -f "cmux-${CMUX_TAG}/Build.*MacOS/cmux DEV" | head -1; }

relaunch_app() {
  local pid; pid=$(app_pid)
  if [ -n "$pid" ]; then
    kill -9 "$pid" 2>/dev/null
    # Wait for the process to actually exit rather than guessing with a
    # sleep: launching the replacement while the old instance still holds
    # the socket makes the new one look dead.
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
      sleep 1; waited=$((waited + 1))
    done
  fi
  # Launch through the login shell so the app runs outside any sandbox.
  ssh cmux-srvA "zsh -lc 'open \"$APP\"'" >/dev/null 2>&1
}

capture_evidence() {
  local seed=$1 kind=$2
  local pid; pid=$(app_pid)
  local out="$DIR/seed-$seed-$kind"
  if [ -n "$pid" ] && [ "$kind" = hang ]; then
    # `sample` needs the user session; route it through the default tmux.
    tmux send-keys -t '1:0' "sample $pid 5 -file $out-sample.txt >/dev/null 2>&1" Enter 2>/dev/null
    sleep 8
  fi
  tail -400 "$DEBUG_LOG" > "$out-debuglog.txt" 2>/dev/null
  ps -o pid,%cpu,state -p "${pid:-0}" > "$out-ps.txt" 2>/dev/null
}

# A freshly relaunched app needs a moment before it can host a mirror:
# the socket comes up first and the workspaces restore after. Poll until
# the workspace list is non-empty rather than sleeping a guessed amount —
# seeds started against a still-restoring app fail setup instantly.
wait_app_ready() {
  local tries=0
  while [ "$tries" -lt 30 ]; do
    if [ -n "$(CMUX_QUIET=1 "$HERE/cmux-debug-cli.sh" list-workspaces 2>/dev/null | head -1)" ]; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 2
  done
  return 1
}

hangs=0; fails=0; crashes=0
relaunch_app
wait_app_ready
for seed in $(seq 1 "$SEEDS"); do
  log="$DIR/seed-$seed.log"
  CMUX_FUZZ_SETTLE_SECS="${CMUX_FUZZ_SETTLE_SECS:-5}" \
    "$HERE/remote-tmux-live-fuzz.sh" "$HOST" "$seed" "$ITERS" > "$log" 2>&1
  rc=$?
  if [ "$rc" -eq 98 ]; then
    # Setup failed: the app had no workspace mirroring the fuzz session,
    # which almost always means the app just died or is mid-restore.
    # Relaunch, wait until it is actually ready, and retry the seed once —
    # burning the remaining seeds against a dead app tells us nothing.
    echo "seed=$seed SETUP FAIL — relaunching app and retrying once"
    capture_evidence "$seed" setup
    relaunch_app
    wait_app_ready
    CMUX_FUZZ_SETTLE_SECS="${CMUX_FUZZ_SETTLE_SECS:-5}" \
      "$HERE/remote-tmux-live-fuzz.sh" "$HOST" "$seed" "$ITERS" > "$log" 2>&1
    rc=$?
  fi
  if [ "$rc" -eq 97 ]; then
    fails=$((fails + 1))
    echo "seed=$seed INERT — fuzzer bug, aborting marathon (fix the fuzzer first)"
    capture_evidence "$seed" inert
    break
  elif [ "$rc" -eq 99 ]; then
    hangs=$((hangs + 1))
    echo "seed=$seed HANG (evidence: seed-$seed-hang-*)"
    capture_evidence "$seed" hang
    relaunch_app
    wait_app_ready
  elif [ -z "$(app_pid)" ]; then
    crashes=$((crashes + 1))
    echo "seed=$seed CRASH (app gone; evidence: seed-$seed-crash-*)"
    capture_evidence "$seed" crash
    relaunch_app
    wait_app_ready
  elif [ "$rc" -ne 0 ]; then
    fails=$((fails + 1))
    echo "seed=$seed FAILURES rc=$rc (see $log)"
    capture_evidence "$seed" fail
  else
    echo "seed=$seed ok"
  fi
done

echo "MARATHON DONE seeds=$SEEDS hangs=$hangs crashes=$crashes fail-seeds=$fails dir=$DIR"
{
  echo "seeds=$SEEDS iters=$ITERS hangs=$hangs crashes=$crashes fail-seeds=$fails"
  grep -l "FUZZ FAIL\|FUZZ HANG" "$DIR"/seed-*.log 2>/dev/null
} > "$DIR/summary.txt"
# Boolean exit — the counts live in the MARATHON DONE line and summary.txt;
# a raw sum could wrap past 255 and read as success.
[ $((hangs + crashes + fails)) -gt 0 ] && exit 1
exit 0
