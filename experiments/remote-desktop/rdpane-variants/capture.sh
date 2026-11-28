#!/bin/bash
# Captures one variant window of rdpane-variants, and nothing else.
# usage: capture.sh <binary> <out.png> <variant> <light|dark> [auto|glass|opaque] [extra app args...]
# Clean env, own PID only, screencapture of the app's own CGWindowID.
set -euo pipefail
bin=$1 out=$2 variant=$3 appearance=$4 material=${5:-auto}
shift $(( $# < 5 ? $# : 5 ))
log=$(mktemp -t rdpv)
env -i HOME="$HOME" USER="$USER" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$bin" --variant "$variant" --appearance "$appearance" --material "$material" --hold 30 "$@" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -f "$log"' EXIT
for _ in $(seq 1 100); do grep -q '^CGWindowID=' "$log" && break; sleep 0.1; done
id=$(sed -n 's/^CGWindowID=\([0-9]*\) .*/\1/p' "$log")
[ -n "$id" ] || { echo "no window id; log:"; cat "$log"; exit 1; }
sleep 1.2   # let the window server composite glass before the capture
screencapture -x -o -l "$id" "$out"
echo "$variant $appearance $material pid=$pid window=$id -> $out"
