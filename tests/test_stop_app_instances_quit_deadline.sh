#!/usr/bin/env bash
# Regression test: cmux_stop_app_instances sent SIGKILL 2 s after SIGTERM. A
# clean cmux-next quit with a Chromium tab open takes 6.5-10 s, so the SIGKILL
# cut the quit cleanup. The stop must wait for each instance to exit (all in
# parallel) until CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS, and send SIGKILL only to
# instances still running after it. macOS only (kqueue process exit events).
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
# matches). On SIGTERM it runs ON_TERM: "quit <seconds> <marker>" finishes a
# clean quit after <seconds> and writes <marker>; "ignore" never quits.
cat > "$TMP_DIR/fake-app.sh" <<'SH'
mode="$1"; delay="${2:-0}"; marker="${3:-}"
if [[ "$mode" == ignore ]]; then
  trap '' TERM
else
  trap '/bin/sleep "$delay"; : > "$marker"; exit 0' TERM
fi
while :; do /bin/sleep 1; done
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

# 2. An instance that ignores SIGTERM gets SIGKILL only after the deadline, with
# a message, and a process of another executable keeps running.
exe2="$TMP_DIR/hung/cmux DEV hung.app/Contents/MacOS/cmux DEV"
start_fake "$exe2" ignore
hung="${PIDS[${#PIDS[@]}-1]}"
start_fake "$TMP_DIR/other/cmux DEV other.app/Contents/MacOS/cmux DEV" ignore
other="${PIDS[${#PIDS[@]}-1]}"
t0="$(now)"
CMUX_STOP_APP_QUIT_TIMEOUT_SECONDS=2 cmux_stop_app_instances "$BUNDLE_ID" "$exe2" 2>"$TMP_DIR/err2"
t2="$(elapsed_since "$t0")"
! kill -0 "$hung" 2>/dev/null || fail "an instance that ignores SIGTERM survived the stop"
ge "$t2" 2 || fail "SIGKILL came after ${t2}s, before the 2 s deadline"
grep -q "clean quit of ${BUNDLE_ID} timed out after 2s; sending SIGKILL to PID(s) ${hung}" "$TMP_DIR/err2" \
  || fail "no timeout message: $(cat "$TMP_DIR/err2")"
kill -0 "$other" 2>/dev/null || fail "the stop killed a process of another executable"
echo "PASS: an instance that ignores SIGTERM gets SIGKILL after the deadline (${t2}s), nothing else is killed"
