#!/usr/bin/env bash
# The journey and perceived-speed runners take an exclusive capture lease (`capture-host acquire --slot
# --exclusive`): with it the fleet controller places no step on the mini and no other capture shares it.
# A journey A/B run beside other agents' steps saw a 1-minute load of 14-24 (2026-10-29); its timings
# were void. Runs each runner against a stand-in capture-host that records how it was asked for a lease
# and grants none, so the runner exits at once.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/capture-host" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CAPTURE_HOST_ARGS_LOG"
echo "capture-host: no lease (test stand-in)" >&2
exit 1
SH
chmod +x "$tmp/bin/capture-host"
# perceived-speed-slot.sh starts acquire with setsid, which macOS lacks.
command -v setsid >/dev/null || { printf '#!/bin/sh\nexec "$@"\n' >"$tmp/bin/setsid"; chmod +x "$tmp/bin/setsid"; }
# A bound with no GNU timeout (macOS): perl's alarm.
bounded() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }
export CAPTURE_HOST_ARGS_LOG="$tmp/args.log" PATH="$tmp/bin:$PATH"

check() { # check NAME: the runner asked for an exclusive slot lease
  local acquire
  acquire=$(grep '^acquire' "$CAPTURE_HOST_ARGS_LOG" || true)
  [ -n "$acquire" ] || { echo "FAIL: $1 never asked capture-host for a lease" >&2; exit 1; }
  if grep -v -- '--exclusive' <<<"$acquire" | grep -q .; then
    echo "FAIL: $1 took a capture lease without --exclusive: $acquire" >&2
    exit 1
  fi
  : >"$CAPTURE_HOST_ARGS_LOG"
}

bounded 60 bash "$ROOT/scripts/cmux-next/restore-journey-slot.sh" 0123456789abcdef01234567 "$tmp/rj" >/dev/null 2>&1 || true
check restore-journey-slot.sh
bounded 60 bash "$ROOT/scripts/cmux-next/perceived-speed-slot.sh" --job 0123456789abcdef01234567 --out "$tmp/ps" >/dev/null 2>&1 || true
check perceived-speed-slot.sh
# A lease printed just before acquire exits, with the run failing after (no ssh to the host here):
# the runner still releases it, so the mini is not held for the lease's 10 minutes.
cat >"$tmp/bin/capture-host" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CAPTURE_HOST_ARGS_LOG"
case "$1" in
  acquire) echo slot-fakehost-0123456789ab; exit 0 ;;
  slot-info) echo "host=fakehost slot=1 root=/nonexistent"; exit 0 ;;
esac
exit 0
SH
printf '#!/bin/sh\nexit 255\n' >"$tmp/bin/ssh"; chmod +x "$tmp/bin/ssh"
cp "$tmp/bin/ssh" "$tmp/bin/scp"
bounded 60 bash "$ROOT/scripts/cmux-next/restore-journey-slot.sh" 0123456789abcdef01234567 "$tmp/rj2" >/dev/null 2>&1 || true
grep -q '^release slot-fakehost-0123456789ab' "$CAPTURE_HOST_ARGS_LOG" ||
  { echo "FAIL: restore-journey-slot.sh did not release its lease: $(cat "$CAPTURE_HOST_ARGS_LOG")" >&2; exit 1; }
: >"$CAPTURE_HOST_ARGS_LOG"
bounded 60 bash "$ROOT/scripts/cmux-next/perceived-speed-slot.sh" --job 0123456789abcdef01234567 --out "$tmp/ps2" >/dev/null 2>&1 || true
grep -q '^release slot-fakehost-0123456789ab' "$CAPTURE_HOST_ARGS_LOG" ||
  { echo "FAIL: perceived-speed-slot.sh did not release its lease: $(cat "$CAPTURE_HOST_ARGS_LOG")" >&2; exit 1; }
# A stop between acquire printing the lease and the runner reading it (the runner polls every 2 s): the
# runner's cleanup must still release that lease. The stand-in prints at 1 s and stays up; TERM at 1.5 s.
cat >"$tmp/bin/capture-host" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CAPTURE_HOST_ARGS_LOG"
case "$1" in
  acquire) sleep 1; echo slot-fakehost-0123456789ab; sleep 30; exit 0 ;;
  slot-info) exit 1 ;;
esac
exit 0
SH
stop_after_print() { # stop_after_print NAME ARGS...: TERM the runner just after the lease is printed
  local name=$1 pid; shift
  : >"$CAPTURE_HOST_ARGS_LOG"
  bash "$ROOT/scripts/cmux-next/$name" "$@" >/dev/null 2>&1 &
  pid=$!
  sleep 1.5
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -q '^release slot-fakehost-0123456789ab' "$CAPTURE_HOST_ARGS_LOG" ||
    { echo "FAIL: $name stopped after acquire printed its lease did not release it" >&2; exit 1; }
}
stop_after_print restore-journey-slot.sh 0123456789abcdef01234567 "$tmp/rj3"
stop_after_print perceived-speed-slot.sh --job 0123456789abcdef01234567 --out "$tmp/ps3"
printf 'capture-runners-exclusive tests: ok\n'
