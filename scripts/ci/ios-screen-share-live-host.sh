#!/bin/bash
# The Mac host of the live Screen Sharing leg (scripts/ci/ios-screen-share-live.sh): InputProbe in front and
# the tagged DEBUG cmux NEXT Mac app sharing this screen, until the file DIR/stop appears. Run by the step
# itself when its processes hold Screen Recording and Accessibility, else inside CmuxScreenEvalLauncher.app
# (scripts/measure/screen-stream-eval.sh ios-live-host=DIR) so both inherit the launcher's console grants.
#
#   ios-screen-share-live-host.sh DIR
#
# DIR/host.env (written by the step, no secret in it): MAC_APP, MAC_TAG, PROBE, HOST_HOME.
# Writes DIR/probe.jsonl (every event InputProbe received), DIR/probe.log, DIR/host.log, DIR/host.pids.
set -u
dir=${1:?DIR}
# shellcheck disable=SC1091
source "$dir/host.env"
: "${MAC_APP:?}" "${MAC_TAG:?}" "${PROBE:?}" "${HOST_HOME:?}"
exe="$MAC_APP/Contents/MacOS/cmux DEV"
[[ -x "$exe" ]] || exe="$(find "$MAC_APP/Contents/MacOS" -maxdepth 1 -type f -perm -u+x -name 'cmux*' | head -1)"
mkdir -p "$dir/state"
[[ -f "$dir/state/cmux.json" ]] || echo "{}" >"$dir/state/cmux.json"
pids=()
stop_all() {
  local p
  for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  for _ in $(seq 1 20); do
    local alive=0
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [[ $alive -eq 0 ]] && break
    sleep 0.5
  done
  for p in "${pids[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
}
trap 'stop_all; exit 0' TERM INT
# The Mac app first (its window off to the side), then InputProbe on top in the middle of the screen,
# where the phone's taps land.
HOME="$HOST_HOME" CMUX_NEXT_NO_ACTIVATE=1 CMUX_NEXT_SOCKET_MODE=automation CMUX_NEXT_TEST_WINDOW_SCREEN=last \
  CMUX_NEXT_CONFIG_FILE="$dir/state/cmux.json" CMUX_NEXT_TEST_WINDOW_FRAME=0,0,560,420 \
  "$exe" >"$dir/host.log" 2>&1 &
pids+=($!)
sleep 3
"$PROBE" "$dir/probe.jsonl" >"$dir/probe.log" 2>&1 &
pids+=($!)
printf '%s\n' "${pids[@]}" >"$dir/host.pids"
# Bounded: the step removes nothing it did not start, and a host left running past the step's own
# timeout would hold the screen, so it ends itself after 90 minutes.
deadline=$((SECONDS + 5400))
while [[ ! -e "$dir/stop" && $SECONDS -lt $deadline ]]; do
  for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null || { echo "host: process $p ended" >>"$dir/host.log"; }; done
  [[ -e "$dir/stop" ]] && break
  sleep 1
done
stop_all
exit 0
