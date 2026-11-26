#!/bin/zsh
# Watches one tagged cmux DEV app for a sustained main-thread spin and, when
# caught, captures the evidence and stops the burn — so a wedged app announces
# itself instead of waiting for a human to notice the beachball.
#
#   cmux-spin-watchdog.sh <tag> [timeout-seconds]
#
# Fires when the app's CPU stays >= $CMUX_SPIN_CPU (default 150%) for
# $CMUX_SPIN_SAMPLES consecutive 5s checks (default 3). On detection it
# writes a stack sample to /tmp/cmux-spin-<tag>-<time>.sample, kills the app,
# and exits 1. Exits 0 if the timeout passes with no spin. Run it unsandboxed
# (sample(1) needs to attach) and in the background: its exit IS the alert.
set -u
TAG="${1:?usage: cmux-spin-watchdog.sh <tag> [timeout-seconds]}"
TIMEOUT="${2:-900}"
THRESH="${CMUX_SPIN_CPU:-150}"
NEED="${CMUX_SPIN_SAMPLES:-3}"
hits=0
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  PID=$(pgrep -f "cmux DEV $TAG.app/Contents/MacOS" | head -1)
  if [ -n "${PID:-}" ]; then
    CPU=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ' | cut -d. -f1)
    if [ "${CPU:-0}" -ge "$THRESH" ]; then
      hits=$((hits + 1))
    else
      hits=0
    fi
    if [ "$hits" -ge "$NEED" ]; then
      STAMP=$(date +%H%M%S)
      OUT="/tmp/cmux-spin-$TAG-$STAMP.sample"
      echo "SPIN DETECTED tag=$TAG pid=$PID cpu=${CPU}% time=$(date +%T)"
      sample "$PID" 2 -file "$OUT" 2>/dev/null && echo "stack sample: $OUT"
      kill "$PID" 2>/dev/null && echo "killed pid $PID"
      exit 1
    fi
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
echo "no spin detected for tag=$TAG in ${TIMEOUT}s"
exit 0
