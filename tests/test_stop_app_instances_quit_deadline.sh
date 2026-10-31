#!/usr/bin/env bash
# Regression test: cmux_stop_app_instances sent SIGKILL 2 s, then 20 s, after
# SIGTERM. A clean cmux-next quit with a Chromium tab open takes 6.5-10 s, and
# a SIGKILL during it loses the app's quit cleanup (saved windows, the agent
# panes' wake states). The stop must wait for each instance to exit (all in
# parallel) until CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS, then send a second
# SIGTERM (the app's force exit) and wait CMUX_STOP_APP_FORCE_EXIT_TIMEOUT_SECONDS,
# and never SIGKILL unless CMUX_STOP_APP_FORCE_KILL=1: an instance that survives
# both signals is left running and the stop returns 1. macOS only (kqueue
# process exit events).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=scripts/lib/stop-app-instances.sh
source "$ROOT_DIR/scripts/lib/stop-app-instances.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-stop-deadline.XXXXXX")"
BUNDLE_ID="com.cmuxterm.test.stopdeadline.$(basename "$TMP_DIR" | tr -cd 'a-zA-Z0-9' | tr '[:upper:]' '[:lower:]')"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true; done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# A fake instance whose command line starts with EXECUTABLE (what pgrep -f
# matches). On SIGTERM it runs MODE: "quit <seconds> <marker>" finishes a
# clean quit after <seconds> and writes <marker>; "second <marker>" ignores the
# first SIGTERM and exits on the second, writing <marker> (a quit stuck until
# the app's force exit); "ignore" never quits.
cat > "$TMP_DIR/fake-app.sh" <<'SH'
mode="$1"; delay="${2:-0}"; marker="${3:-}"
case "$mode" in
  ignore) trap '' TERM ;;
  second) marker="$delay"; terms=0
    trap 'terms=$((terms + 1)); if [[ $terms -ge 2 ]]; then : > "$marker"; exit 0; fi' TERM ;;
  *) trap '/bin/sleep "$delay"; : > "$marker"; exit 0' TERM ;;
esac
while :; do /bin/sleep 0.2; done
SH
start_fake() {
  local executable="$1"; shift
  # Detached (launchd reaps it), so kill -0 reports the real exit.
  ( bash -c 'exec -a "$0" /bin/bash "$@"' "$executable" "$TMP_DIR/fake-app.sh" "$@" \
      >/dev/null 2>&1 &
    echo "$!" > "$TMP_DIR/pid" )
  PIDS+=("$(cat "$TMP_DIR/pid")")
  # Let bash install its trap before the stop signals it.
  for _ in {1..50}; do
    pgrep -f -- "^$(cmux_regex_escape "$executable")( |\$)" >/dev/null && break
    /bin/sleep 0.05
  done
  /bin/sleep 0.2
}
now() { /usr/bin/python3 -c 'import time; print(time.time())'; }
elapsed_since() { /usr/bin/python3 -c "import sys, time; print(round(time.time() - float(sys.argv[1]), 2))" "$1"; }
ge() { /usr/bin/python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" "$1" "$2"; }

# 1. Two instances that each need 3 s to quit cleanly (the old stop killed them
# at 2 s), deadline 10 s: both quit on their own, no SIGKILL. Both get SIGTERM
# up front, so their quits run in parallel and finish together.
exe="$TMP_DIR/slow/cmux DEV slow.app/Contents/MacOS/cmux DEV"
start_fake "$exe" quit 3 "$TMP_DIR/clean-a"
start_fake "$exe" quit 3 "$TMP_DIR/clean-b"
slow_a="${PIDS[0]}"; slow_b="${PIDS[1]}"
t0="$(now)"
CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS=10 cmux_stop_app_instances "$BUNDLE_ID" "$exe" 2>"$TMP_DIR/err1"
t1="$(elapsed_since "$t0")"
[[ -e "$TMP_DIR/clean-a" && -e "$TMP_DIR/clean-b" ]] \
  || fail "an instance was killed before it finished its clean quit (elapsed ${t1}s)"
if kill -0 "$slow_a" 2>/dev/null || kill -0 "$slow_b" 2>/dev/null; then fail "an instance still runs after the stop"; fi
! grep -q SIGKILL "$TMP_DIR/err1" || fail "the stop reported a SIGKILL for clean quits: $(cat "$TMP_DIR/err1")"
ge "$t1" 2.5 || fail "the stop returned after ${t1}s, before the instances quit"
spread="$(/usr/bin/python3 -c 'import os, sys; a, b = (os.stat(p).st_mtime for p in sys.argv[1:]); print(round(abs(a - b), 2))' \
  "$TMP_DIR/clean-a" "$TMP_DIR/clean-b")"
ge 1.5 "$spread" || fail "the clean quits finished ${spread}s apart; SIGTERM was not sent to both up front"
echo "PASS: two 3 s clean quits finish without SIGKILL, in parallel (stop ${t1}s, quits ${spread}s apart)"

# 2. An instance whose quit only finishes on the second SIGTERM (the app's
# force exit) gets it after the deadline, and no SIGKILL: the stop succeeds.
exe2="$TMP_DIR/stuck/cmux DEV stuck.app/Contents/MacOS/cmux DEV"
start_fake "$exe2" second "$TMP_DIR/forced"
forced_pid="${PIDS[${#PIDS[@]}-1]}"
t0="$(now)"
CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS=2 CMUX_STOP_APP_FORCE_EXIT_TIMEOUT_SECONDS=3 \
  cmux_stop_app_instances "$BUNDLE_ID" "$exe2" 2>"$TMP_DIR/err2" \
  || fail "the stop failed although the second SIGTERM ended the instance: $(cat "$TMP_DIR/err2")"
t2="$(elapsed_since "$t0")"
[[ -e "$TMP_DIR/forced" ]] || fail "the instance did not exit through the second SIGTERM"
! kill -0 "$forced_pid" 2>/dev/null || fail "the instance still runs after the second SIGTERM"
ge "$t2" 2 || fail "the second SIGTERM came after ${t2}s, before the 2 s deadline"
grep -q "clean quit of ${BUNDLE_ID} timed out after 2s; sending a second SIGTERM (the app's force exit) to PID(s) ${forced_pid}" "$TMP_DIR/err2" \
  || fail "no second-SIGTERM message: $(cat "$TMP_DIR/err2")"
! grep -q SIGKILL "$TMP_DIR/err2" || fail "the stop reported a SIGKILL: $(cat "$TMP_DIR/err2")"
echo "PASS: a quit that needs the force exit ends on the second SIGTERM after the deadline (${t2}s), no SIGKILL"

# 3. An instance that ignores SIGTERM is never SIGKILLed: after the deadline
# and the force-exit grace it is left running, the stop returns 1 with a
# message, and a process of another executable keeps running.
exe3="$TMP_DIR/hung/cmux DEV hung.app/Contents/MacOS/cmux DEV"
start_fake "$exe3" ignore
hung="${PIDS[${#PIDS[@]}-1]}"
start_fake "$TMP_DIR/other/cmux DEV other.app/Contents/MacOS/cmux DEV" ignore
other="${PIDS[${#PIDS[@]}-1]}"
t0="$(now)"
status=0
CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS=1 CMUX_STOP_APP_FORCE_EXIT_TIMEOUT_SECONDS=1 \
  cmux_stop_app_instances "$BUNDLE_ID" "$exe3" 2>"$TMP_DIR/err3" || status=$?
t3="$(elapsed_since "$t0")"
[[ "$status" -ne 0 ]] || fail "the stop returned 0 although the instance still runs"
kill -0 "$hung" 2>/dev/null || fail "an instance that ignores SIGTERM was killed (SIGKILL is opt-in only)"
ge "$t3" 2 || fail "the stop gave up after ${t3}s, before the 1 s deadline plus the 1 s force-exit grace"
grep -q "${BUNDLE_ID} PID(s) ${hung} still running 1s after SIGTERM and 1s after a second SIGTERM; left running, not replaced" "$TMP_DIR/err3" \
  || fail "no left-running message: $(cat "$TMP_DIR/err3")"
grep -q "sending a second SIGTERM" "$TMP_DIR/err3" || fail "no second SIGTERM was sent: $(cat "$TMP_DIR/err3")"
! grep -q "sending SIGKILL" "$TMP_DIR/err3" || fail "the stop sent SIGKILL by default: $(cat "$TMP_DIR/err3")"
kill -0 "$other" 2>/dev/null || fail "the stop signalled a process of another executable"
echo "PASS: an instance that ignores SIGTERM is left running, the stop fails (${t3}s, exit ${status}), no SIGKILL"

# 4. CMUX_STOP_APP_FORCE_KILL=1 opts back into SIGKILL for that instance, and
# the stop then succeeds.
CMUX_STOP_APP_FORCE_KILL=1 CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS=1 CMUX_STOP_APP_FORCE_EXIT_TIMEOUT_SECONDS=1 \
  cmux_stop_app_instances "$BUNDLE_ID" "$exe3" 2>"$TMP_DIR/err4" \
  || fail "the opt-in force kill failed: $(cat "$TMP_DIR/err4")"
! kill -0 "$hung" 2>/dev/null || fail "CMUX_STOP_APP_FORCE_KILL=1 did not kill the instance"
grep -q "PID(s) ${hung} still running 1s after the second SIGTERM; sending SIGKILL (CMUX_STOP_APP_FORCE_KILL=1)" "$TMP_DIR/err4" \
  || fail "no SIGKILL message: $(cat "$TMP_DIR/err4")"
kill -0 "$other" 2>/dev/null || fail "the force kill hit a process of another executable"
echo "PASS: CMUX_STOP_APP_FORCE_KILL=1 kills an instance that survives both signals, nothing else"
