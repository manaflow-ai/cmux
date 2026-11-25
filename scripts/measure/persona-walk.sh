#!/usr/bin/env bash
# Persona dogfood walk (cmuxterm-hq docs/dogfood/personas): a fresh NEXT NIGHTLY on a fleet Mac, driven the way a
# person would, with timings and screenshots returned as one artifact.
#
#   cmux-ci run --class exclusive --display --measurement --pin-strict --label measure --script scripts/measure/persona-walk.sh \
#     --ref SHA --target-worker HOST --artifact artifacts/persona-walk/report.tgz --arg=mode=probe
#   (SHA on feat-cmux-next or main; the job needs an open PR for the branch it runs from.)
#
# mode=probe   what the step can see: user, console session, displays, cmux CLI, Computer Use readiness.
# mode=p0      P0 task 1: download the newest NIGHTLY, install a scratch copy, launch it, time to first window.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

mode=probe
appcast=https://files-next.cmux.com/nightly-next/appcast-arm64.xml
for a in "$@"; do
  case "$a" in
    mode=*) mode=${a#mode=} ;;
    appcast=*) appcast=${a#appcast=} ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

out=artifacts/persona-walk
mkdir -p "$out/shots"
work=$(mktemp -d /tmp/persona-walk.XXXXXX)
log="$out/log.txt"
: >"$log"
note() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$log"; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
# macOS has no timeout(1): perl's alarm bounds a command the same way.
to() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
# The cmux CLI on a fleet PATH is a dev shim; use the CLI inside an app bundle.
app_cli() { local c; for c in "$1/Contents/Resources/bin/cmux" "$1/Contents/MacOS/cmux-cli"; do [ -x "$c" ] && { echo "$c"; return; }; done; }
pack() { tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null; }
# Every process this run started lives under $work: stop them all at exit, so no scratch app or daemon outlives the step.
# Earlier runs' scratch apps (any /tmp/persona-walk.* copy, only this script makes them) go too: one leaked copy holds 1.5 GB.
reap() { local pids; pids=$(pgrep -f "/persona-walk\.[A-Za-z0-9]{6}/" | grep -v "^$$\$" || true); [ -n "$pids" ] && { note "reap $(echo $pids)"; kill $pids 2>/dev/null; }; }
trap 'reap; pack' EXIT
inventory() { # inventory LABEL: every cmux process on the host (path, RSS), and memory pressure
  { echo "--- inventory $1"; ps -axo pid=,rss=,comm= | grep -i "cmux" | grep -v "scripts/measure/persona-walk"
    memory_pressure 2>/dev/null | tail -1; } >>"$log" 2>&1; }
inventory start; reap

probe() {
  note "mode=probe host=$(hostname -s) user=$(id -un) uid=$(id -u)"
  note "console user: $(stat -f %Su /dev/console 2>/dev/null)"
  note "sw_vers: $(sw_vers -productVersion 2>/dev/null)"
  { echo "--- who"; who; echo "--- launchctl gui domain"; launchctl print "gui/$(id -u)" 2>&1 | head -5
    echo "--- displays"; system_profiler SPDisplaysDataType 2>&1 | grep -E "Resolution|Display Type|Online|Main" | head
    echo "--- cmux on PATH"; command -v cmux; cmux --version 2>&1 | head -3
    echo "--- installed apps"; ls -d /Applications/cmux*.app ~/Applications/cmux*.app 2>/dev/null
    echo "--- running cmux"; pgrep -fl 'cmux' | grep -v persona-walk | head
    echo "--- app bundle CLIs"; ls "/Applications/cmux NIGHTLY.app/Contents/Resources/bin" 2>&1 | head
    CLI=$(app_cli "/Applications/cmux NIGHTLY.app"); echo "cli=$CLI"
    if [ -n "$CLI" ]; then
      echo "--- computer-use status"; to 30 "$CLI" computer-use status 2>&1 | head -30
      echo "--- computer-use doctor"; to 60 "$CLI" computer-use doctor 2>&1 | head -60
    fi
    echo "--- screencapture"; to 20 screencapture -x "$out/shots/probe-screen.png" && echo ok
  } >>"$log" 2>&1
}

install_nightly() {
  local t0 url
  t0=$(now_ms)
  url=$(curl -fsSL "$appcast" | python3 -c 'import re,sys;m=re.findall(r"url=\"([^\"]+\.dmg)\"",sys.stdin.read());print(m[0] if m else "")')
  [ -n "$url" ] || { note "FAIL no dmg in appcast"; return 1; }
  note "dmg $url"
  curl -fsSL -o "$work/n.dmg" "$url" || { note "FAIL download"; return 1; }
  hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$work/n.dmg" >/dev/null || { note "FAIL attach"; return 1; }
  local app; app=$(ls -d "$work"/mnt/*.app | head -1)
  mkdir -p "$work/Applications"; ditto "$app" "$work/Applications/$(basename "$app")"
  hdiutil detach "$work/mnt" >/dev/null 2>&1
  APP="$work/Applications/$(basename "$app")"
  note "installed $(basename "$APP") in $(( $(now_ms) - t0 )) ms"
  echo "{\"dmg\":\"$url\",\"install_ms\":$(( $(now_ms) - t0 ))}" >"$out/install.json"
}

# CuaDriver holds the fleet Mac's Screen Recording and Accessibility grants (a scratch app copy has none); its client
# finds the daemon under the account's own HOME, not the step's fresh one.
memory() { # memory LABEL PID: the app's physical footprint (what Force Quit shows) and every process the copy started
  { echo "--- memory $1"; footprint "$2" 2>&1 | grep -iE "footprint|phys" | head -3
    ps -axo pid=,ppid=,rss=,command= | grep "/persona-walk\.[A-Za-z0-9]\{6\}/" | grep -v grep | cut -c1-220; } >>"$log" 2>&1
  printf '{"label":"%s","footprint":"%s"}\n' "$1" "$(footprint "$2" 2>/dev/null | grep -i "footprint" | head -1 | tr -s ' ' | tr -d '"')" >>"$out/memory.jsonl"; }
CUA=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
cua() { HOME=$(eval echo "~$(id -un)") to 30 env -u CFFIXED_USER_HOME "$CUA" call "$@"; }
shot() { cua get_desktop_state "{\"screenshot_out_file\":\"$PWD/$out/shots/$1.png\"}" >"$out/state-$1.json" 2>&1; note "shot $1 rc=$?"; }
step() { # step NAME START_MS: one timed step in timings.json
  printf '{"step":"%s","ms":%s}\n' "$1" "$(( $(now_ms) - $2 ))" >>"$out/timings.jsonl"; note "step $1 $(( $(now_ms) - $2 )) ms"; }

p0() {
  probe
  { echo "--- cua-driver"; ls -l "$CUA"; HOME=$(eval echo "~$(id -un)") to 20 "$CUA" --help 2>&1 | head -40; } >>"$log" 2>&1
  local t
  t=$(now_ms); install_nightly || return 1; step install "$t"
  local cli; cli=$(app_cli "$APP"); note "scratch cli=$cli"
  inventory before-launch
  # A fresh person has no cmux state: own HOME and TMPDIR (the daemon socket is under TMPDIR, keyed by uid, so a
  # NIGHTLY already running as this user would otherwise serve this copy its sessions).
  mkdir -p "$work/home" "$work/tmp"
  t=$(now_ms)
  open -n --env HOME="$work/home" --env TMPDIR="$work/tmp/" --env CFFIXED_USER_HOME="$work/home" -a "$APP" 2>>"$log"
  local pid="" win=""
  for _ in $(seq 1 240); do
    [ -n "$pid" ] || pid=$(pgrep -nf "$APP/Contents/MacOS/" || true)
    if [ -n "$pid" ] && cua list_windows "{\"pid\":$pid}" >"$out/cua-windows.json" 2>&1 && grep -q '"window_id"\|"windowId"\|"id"' "$out/cua-windows.json"; then win=1; break; fi
    python3 -c 'import time;time.sleep(0.25)'
  done
  [ -n "$win" ] && step first_window "$t" || note "STUCK no window in 60 s (pid=$pid)"
  memory first-window "$pid"
  shot 01-first-window
  python3 -c 'import time;time.sleep(5)'
  shot 02-after-5s
  memory after-5s "$pid"
  # The app owns many windows (panels, menus) and replaces its main one after launch: re-list right before typing and
  # name the on-screen titled one, or cua refuses the target as ambiguous or stale.
  local wid=""
  cua list_windows "{\"pid\":$pid}" >"$out/cua-windows-2.json" 2>&1
  wid=$(python3 -c 'import json,sys;w=[x for x in json.load(open(sys.argv[1])).get("windows",[]) if x.get("is_on_screen") and x.get("title") and x.get("layer",0)==0];print(w[0]["window_id"] if w else "")' "$out/cua-windows-2.json" 2>/dev/null)
  note "window_id=$wid"
  # P0 task 1: a person types their first command into whatever the app shows.
  t=$(now_ms)
  cua type_text "{\"pid\":$pid,\"window_id\":${wid:-0},\"text\":\"echo persona-ok\"}" >>"$log" 2>&1 || note "type_text rc=$?"
  cua press_key "{\"pid\":$pid,\"window_id\":${wid:-0},\"key\":\"return\"}" >>"$log" 2>&1 || note "press_key rc=$?"
  python3 -c 'import time;time.sleep(1)'
  step first_command "$t"
  shot 03-first-command
  [ -n "$cli" ] && to 30 "$cli" computer-use status >"$out/cu-status.txt" 2>&1
  # The Chief's answer to the first message: a failed turn is a stuck point (the person reached no value).
  # The failure lands a few seconds after the send: look for up to 20 s.
  local failed="" _i
  for _i in $(seq 1 40); do
    failed=$(grep -rhao '"text":"the turn failed ([^"]\{0,160\}' "$work/home/.cmux/chief" 2>/dev/null | head -1 | cut -c9-)
    [ -n "$failed" ] && break; python3 -c 'import time;time.sleep(0.5)'
  done
  [ -n "$failed" ] && note "STUCK first message: $failed"
  memory after-walk "$pid"
  inventory after-walk
  # What the app wrote for this fresh person (the Chief's error, daemon logs): text logs only, size-capped. The home is
  # the run's own, so it holds no credentials.
  ( cd "$work/home" && find . -type f \( -name '*.log' -o -name '*.jsonl' -o -name '*.txt' \) -size -2M 2>/dev/null | head -200 |
      tar -czf "$work/home-logs.tgz" -T - 2>/dev/null ); cp "$work/home-logs.tgz" "$out/" 2>/dev/null
  find "$work/home" -maxdepth 4 2>/dev/null | sed "s|$work/home|~|" | head -200 >"$out/home-tree.txt"
}

case "$mode" in
  probe) probe ;;
  p0) p0 ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
note "done"
