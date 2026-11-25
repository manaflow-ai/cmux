#!/usr/bin/env bash
# Golden interactions (motion guard, cx-codh2) on a 120 Hz virtual display.
#
# usage: golden.sh WORK_DIR
#   WORK_DIR holds the tagged app (app/*.app) and VDisplay.app, as for bench.sh. Run it in
#   the console user's GUI session (console-session.sh); CMUX_TAG is the app's baked tag.
#
# Brings up the virtual display, launches the app on it (no activation, automation socket,
# an empty config of its own, the mock agent pane), runs `golden.py drive` into
# out/golden/, and quits the app through its socket (quitEndSessions). Only the exact PIDs
# this script started are ever signaled. Judging is a separate step (`golden.py judge`).
set -uo pipefail

work="${1:?usage: golden.sh WORK_DIR}"
tag="${CMUX_TAG:?set CMUX_TAG to the baked tag of the app}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$work/out/golden"
mkdir -p "$out"
app="$(ls -d "$work"/app/*.app 2>/dev/null | head -1)"
[ -n "$app" ] || { echo "no app under $work/app" >&2; exit 1; }
binary="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
slug="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | sed -E -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//')"
socket="/tmp/cmux-debug-$slug.sock"

# shellcheck source=SCRIPTDIR/../../lib/stop-cmux-tui-owners.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/stop-cmux-tui-owners.sh"

display_pid=""
app_pid=""

# Waits up to $2 seconds for PID $1 to exit.
wait_exit() {
  local pid="$1" seconds="$2"
  for _ in $(seq $((seconds * 4))); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  return 1
}

teardown() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    python3 "$here/app-rpc.py" "$socket" action.run '{"action":"quitEndSessions"}' >/dev/null 2>&1 || true
    wait_exit "$app_pid" 20 || { kill -TERM "$app_pid" 2>/dev/null; wait_exit "$app_pid" 10 || kill -KILL "$app_pid" 2>/dev/null; }
  fi
  cmux_stop_cmux_tui_owners "$app/Contents/Resources/bin"
  # Helpers that outlived the quit (acpmux, browser hosts, CEF helpers): only processes whose
  # executable lives inside this run's app bundle, each by its exact PID.
  local pid comm
  while read -r pid comm; do
    [[ "$comm" == "$app/"* ]] || continue
    echo "lingering after quit: $pid $comm" | tee -a "$out/lingering.txt" >&2
    kill -TERM "$pid" 2>/dev/null || true
  done < <(ps -axww -o pid= -o comm= 2>/dev/null)
  if [ -n "$display_pid" ]; then
    kill -TERM "$display_pid" 2>/dev/null || true
    wait_exit "$display_pid" 5 || kill -KILL "$display_pid" 2>/dev/null || true
  fi
}
trap teardown EXIT

"$work/VDisplay.app/Contents/MacOS/VDisplay" 120 1800 >"$out/vdisplay.out" 2>"$out/vdisplay.err" &
display_pid=$!
for _ in $(seq 20); do
  grep -q '^ready\|^error' "$out/vdisplay.out" 2>/dev/null && break
  sleep 1
done
cat "$out/vdisplay.out"
grep -q '^ready' "$out/vdisplay.out" || { echo "error: the virtual display never came up" >&2; exit 0; }

printf '{}\n' > "$out/cmux-next.json"
rm -f "$socket"
env CMUX_TAG="$tag" CMUX_NEXT_AGENT_PANE_MOCK=1 CMUX_NEXT_SOCKET_MODE=automation CMUX_NEXT_NO_ACTIVATE=1 \
  CMUX_DEV_BACKEND_MODE=local CMUX_NEXT_AGENT_PANE_FULL_RATE=1 CMUX_NEXT_CONFIG_FILE="$out/cmux-next.json" \
  CMUX_NEXT_TEST_WINDOW_SCREEN=last CMUX_NEXT_TEST_WINDOW_FRAME=80,80,1100,720 \
  "$binary" >"$out/app.log" 2>&1 </dev/null &
app_pid=$!
for _ in $(seq 90); do [ -S "$socket" ] && break; sleep 1; done
if [ ! -S "$socket" ]; then
  echo "error: no socket at $socket" | tee "$out/error.txt"
  exit 0
fi
sleep 5
python3 "$here/golden.py" drive "$socket" "$out"
