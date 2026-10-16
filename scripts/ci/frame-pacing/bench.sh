#!/usr/bin/env bash
# Fling bench for the cmux-next agent pane on a 120 Hz virtual display.
#
# usage: bench.sh WORK_DIR [FLINGS]
#   WORK_DIR holds the tagged app (app/*.app), VDisplay.app (built from
#   vdisplay.m) and an out/ directory. Run it in the console user's GUI session
#   (scripts/ci/run-in-console-session.sh); CMUX_TAG is the app's baked tag.
#
# For each render rate (CMUX_NEXT_AGENT_PANE_FULL_RATE=0 capped, =1 full) it
# launches the app with the mock agent pane, seeds 5000 rows, runs one warm-up
# fling and FLINGS measured flings (3 by default; an argument, because
# run-in-console-session.sh forwards only a fixed list of variables), and writes out/<mode>-<n>.json with the
# fling_stats and perf_stats debug results. out/display.txt records the virtual
# display's measured tick interval. The virtual display and every app this
# script launched are gone when it exits, however it exits.
set -uo pipefail

work="${1:?usage: bench.sh WORK_DIR}"
tag="${CMUX_TAG:?set CMUX_TAG to the baked tag of the app}"
flings="${2:-3}"
case "$flings" in ""|*[!0-9]*) echo "FLINGS must be a number, got: $flings" >&2; exit 1 ;; esac
out="$work/out"
mkdir -p "$out"
app="$(ls -d "$work"/app/*.app 2>/dev/null | head -1)"
[ -n "$app" ] || { echo "no app under $work/app" >&2; exit 1; }
cli="$app/Contents/Resources/bin/cmux"
# The debug socket follows the tag's path slug (scripts/cmux-debug-cli.sh).
slug="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | sed -E -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//')"
socket="/tmp/cmux-debug-$slug.sock"

teardown() {
  pkill -f "$app/" 2>/dev/null || true
  pkill -f "$work/VDisplay.app/" 2>/dev/null || true
  sleep 1
  system_profiler SPDisplaysDataType 2>/dev/null | grep -m1 'UI Looks like' | sed 's/^ */main display after teardown: /' || true
}
trap teardown EXIT

open --stdout "$out/vdisplay.out" --stderr "$out/vdisplay.err" "$work/VDisplay.app" --args 120 1800
for _ in $(seq 20); do
  grep -q '^ready\|^error' "$out/vdisplay.out" 2>/dev/null && break
  sleep 1
done
cp "$out/vdisplay.out" "$out/display.txt" 2>/dev/null || echo "error: the virtual display never reported" > "$out/display.txt"
cat "$out/display.txt"
grep -q '^ready' "$out/display.txt" || exit 0

rpc() { CMUX_SOCKET_PATH="$socket" "$cli" rpc debug.agent_pane "$1" 2>&1; }

for mode in 0 1; do
  rm -f "$socket"
  open -n "$app" --env CMUX_TAG="$tag" --env CMUX_NEXT_AGENT_PANE_MOCK=1 \
    --env CMUX_NEXT_SOCKET_MODE=automation --env CMUX_NEXT_NO_ACTIVATE=1 \
    --env CMUX_DEV_BACKEND_MODE=local --env CMUX_NEXT_AGENT_PANE_FULL_RATE="$mode"
  for _ in $(seq 90); do [ -S "$socket" ] && break; sleep 1; done
  if [ ! -S "$socket" ]; then
    echo "mode $mode: no socket at $socket" | tee "$out/$mode-error.txt"
    pkill -f "$app/" 2>/dev/null || true
    continue
  fi
  sleep 3
  CMUX_SOCKET_PATH="$socket" "$cli" agent new-chat >/dev/null 2>&1
  sleep 4
  rpc '{"action":"seed_rows","count":5000}' >/dev/null
  sleep 3
  for n in $(seq 0 "$flings"); do
    rpc '{"action":"fling"}' >/dev/null
    sleep 5
    # Fling 0 warms the transcript's layout and is not reported.
    [ "$n" = 0 ] && continue
    printf '{"fling":%s,"perf":%s}\n' "$(rpc '{"action":"fling_stats"}')" "$(rpc '{"action":"perf_stats"}')" > "$out/$mode-$n.json"
  done
  pkill -f "$app/" 2>/dev/null || true
  sleep 2
done
