#!/bin/bash
# Long unattended run of the live layout fuzz: many seeds, evidence capture,
# automatic recovery. Every failure or hang leaves enough on disk to
# reproduce and diagnose it: the seed and iteration, the fuzz log, the app's
# debug log tail, and — for hangs — a process sample taken while stuck.
#
# Usage: CMUX_TAG=main scripts/remote-tmux-fuzz-marathon.sh <ssh-host> [seeds] [iters-per-seed]
# Set CMUX_FUZZ_RELAUNCH_HOST only when the app must be opened through a
# separate login host; by default the marathon relaunches it locally.
# Output: a private /tmp/cmux-fuzz-marathon.XXXXXXXX/ directory printed at start.
set -u
umask 077

HOST="${1:?usage: CMUX_TAG=<tag> $0 <ssh-host> [seeds] [iters]}"
SEEDS="${2:-40}"
ITERS="${3:-25}"
: "${CMUX_TAG:?CMUX_TAG is required}"
RELAUNCH_HOST="${CMUX_FUZZ_RELAUNCH_HOST:-}"
LOCAL_TMP_ROOT="${TMPDIR:-/tmp}"
LOCAL_TMP_ROOT="${LOCAL_TMP_ROOT%/}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/mobile-attach.sh"
cmux_attach_validate_dev_tag "$CMUX_TAG" || exit 2
TAG_SLUG="$(cmux_attach__slug "$CMUX_TAG")"
APP="${CMUX_FUZZ_APP:-$(cmux_attach_mac_app_path "$CMUX_TAG")}"
APP_EXECUTABLE="$APP/Contents/MacOS/cmux DEV"
DEBUG_LOG="${CMUX_FUZZ_DEBUG_LOG:-/tmp/cmux-debug-${TAG_SLUG}.log}"
export CMUX_FUZZ_DEBUG_LOG="$DEBUG_LOG"
. "$HERE/remote-tmux-fuzz-lock.sh"
# Exactly one driver. Concurrent marathons share one app and one tmux lab,
# and each seed's setup kills the lab server — yanking layouts out from
# under the other run's iterations and manufacturing failures no code
# produced. The shared helper owns the one atomic acquire/validate/release
# path; its pid/token files live privately inside the lock directory.
CMUX_FUZZ_LOCK_OWNED=0
# Hold the lock for the whole run: the trap releases it on ANY exit
# (including SIGTERM), so nobody ever needs to delete it by hand — and
# deleting it by hand is exactly how two drivers once ran concurrently.
cleanup() {
  local status=$?
  trap - EXIT
  cmux_fuzz_lock_release
  exit "$status"
}
trap cleanup EXIT
cmux_fuzz_lock_acquire "$LOCAL_TMP_ROOT" || exit $?
DIR=$(mktemp -d "$LOCAL_TMP_ROOT/cmux-fuzz-marathon.XXXXXXXX") || {
  echo "could not create private marathon evidence directory" >&2
  exit 2
}
echo "marathon: $SEEDS seeds x $ITERS iters -> $DIR"

app_pid() {
  local command remote_command pid executable
  if [ -n "$RELAUNCH_HOST" ]; then
    printf -v command 'target=%q; ps -axo pid=,comm= | while read -r pid executable; do if [ "$executable" = "$target" ]; then printf "%%s\\n" "$pid"; break; fi; done' "$APP_EXECUTABLE"
    printf -v remote_command 'zsh -lc %q' "$command"
    ssh "$RELAUNCH_HOST" "$remote_command" 2>/dev/null
  else
    while read -r pid executable; do
      if [ "$executable" = "$APP_EXECUTABLE" ]; then
        printf '%s\n' "$pid"
        break
      fi
    done < <(ps -axo pid=,comm=)
  fi
}

app_process_alive() {
  local pid=$1 command remote_command
  if [ -n "$RELAUNCH_HOST" ]; then
    printf -v command 'kill -0 %q' "$pid"
    printf -v remote_command 'zsh -lc %q' "$command"
    ssh "$RELAUNCH_HOST" "$remote_command" >/dev/null 2>&1
  else
    kill -0 "$pid" 2>/dev/null
  fi
}

terminate_app() {
  local pid=$1 command remote_command
  if [ -n "$RELAUNCH_HOST" ]; then
    printf -v command 'kill -9 %q' "$pid"
    printf -v remote_command 'zsh -lc %q' "$command"
    ssh "$RELAUNCH_HOST" "$remote_command" >/dev/null 2>&1
  else
    kill -9 "$pid" 2>/dev/null
  fi
}

relaunch_app() {
  local pid launch_command remote_command
  pid=$(app_pid)
  if [ -n "$pid" ]; then
    terminate_app "$pid"
    # Wait for the process to actually exit rather than guessing with a
    # sleep: launching the replacement while the old instance still holds
    # the socket makes the new one look dead.
    local waited=0
    while app_process_alive "$pid" && [ "$waited" -lt 20 ]; do
      sleep 1; waited=$((waited + 1))
    done
    if app_process_alive "$pid"; then
      echo "ERROR: old app pid $pid did not exit after 20s" >&2
      return 1
    fi
  fi
  # Launch through a login shell so the app runs outside any sandbox. Most
  # runs are local; lab machines that need a GUI-session hop opt in with
  # CMUX_FUZZ_RELAUNCH_HOST instead of relying on one maintainer's ssh alias.
  printf -v launch_command 'open %q' "$APP"
  if [ -n "$RELAUNCH_HOST" ]; then
    printf -v remote_command 'zsh -lc %q' "$launch_command"
    ssh "$RELAUNCH_HOST" "$remote_command" >/dev/null 2>&1
  else
    zsh -lc "$launch_command" >/dev/null 2>&1
  fi
}

capture_evidence() {
  local seed=$1 kind=$2
  local pid; pid=$(app_pid)
  local out="$DIR/seed-$seed-$kind"
  if [ -n "$pid" ] && [ "$kind" = hang ]; then
    if [ -n "$RELAUNCH_HOST" ]; then
      local sample_command remote_command
      printf -v sample_command '/usr/bin/sample %q 5' "$pid"
      printf -v remote_command 'zsh -lc %q' "$sample_command"
      if ! ssh "$RELAUNCH_HOST" "$remote_command" > "$out-sample.txt" 2>&1; then
        echo "remote sample failed via $RELAUNCH_HOST" >> "$out-sample.txt"
      fi
    elif ! /usr/bin/sample "$pid" 5 -file "$out-sample.txt" >/dev/null 2>&1; then
      echo "local sample failed for pid $pid" > "$out-sample.txt"
    fi
  fi
  if [ -n "$RELAUNCH_HOST" ]; then
    local tail_command ps_command remote_tail remote_ps
    printf -v tail_command 'tail -400 %q' "$DEBUG_LOG"
    printf -v ps_command 'ps -o pid,%%cpu,state -p %q' "${pid:-0}"
    printf -v remote_tail 'zsh -lc %q' "$tail_command"
    printf -v remote_ps 'zsh -lc %q' "$ps_command"
    ssh "$RELAUNCH_HOST" "$remote_tail" > "$out-debuglog.txt" 2>/dev/null
    ssh "$RELAUNCH_HOST" "$remote_ps" > "$out-ps.txt" 2>/dev/null
  else
    tail -400 "$DEBUG_LOG" > "$out-debuglog.txt" 2>/dev/null
    ps -o pid,%cpu,state -p "${pid:-0}" > "$out-ps.txt" 2>/dev/null
  fi
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

restart_app_ready() {
  local reason=$1
  if ! relaunch_app; then
    echo "ERROR: $reason relaunch failed${RELAUNCH_HOST:+ via $RELAUNCH_HOST}" >&2
    return 1
  fi
  if ! wait_app_ready; then
    echo "ERROR: $reason app never became ready after relaunch" >&2
    return 1
  fi
}

hangs=0; fails=0; crashes=0
if ! restart_app_ready initial; then
  exit 1
fi
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
    if ! restart_app_ready "seed=$seed setup recovery"; then
      fails=$((fails + 1))
      break
    fi
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
    if ! restart_app_ready "seed=$seed hang recovery"; then
      break
    fi
  elif [ -z "$(app_pid)" ]; then
    crashes=$((crashes + 1))
    echo "seed=$seed CRASH (app gone; evidence: seed-$seed-crash-*)"
    capture_evidence "$seed" crash
    if ! restart_app_ready "seed=$seed crash recovery"; then
      break
    fi
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
