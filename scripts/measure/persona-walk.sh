#!/usr/bin/env bash
# Persona dogfood walk (cmuxterm-hq docs/dogfood/personas): a fresh NEXT NIGHTLY on a fleet Mac, driven the way a
# person would, with timings and screenshots returned as one artifact.
#
#   cmux-ci run --class exclusive --display --label measure --script scripts/measure/persona-walk.sh \
#     --ref SHA --target-worker HOST --artifact artifacts/persona-walk/report.tgz --arg=mode=probe
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
trap pack EXIT

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
  t=$(now_ms)
  open -n -a "$APP" 2>>"$log"
  local pid="" win=""
  for _ in $(seq 1 240); do
    [ -n "$pid" ] || pid=$(pgrep -nf "$APP/Contents/MacOS/" || true)
    if [ -n "$pid" ] && cua list_windows "{\"pid\":$pid}" >"$out/cua-windows.json" 2>&1 && grep -q '"window_id"\|"windowId"\|"id"' "$out/cua-windows.json"; then win=1; break; fi
    python3 -c 'import time;time.sleep(0.25)'
  done
  [ -n "$win" ] && step first_window "$t" || note "STUCK no window in 60 s (pid=$pid)"
  shot 01-first-window
  python3 -c 'import time;time.sleep(5)'
  shot 02-after-5s
  # P0 task 1: a person types their first command into whatever the app shows.
  t=$(now_ms)
  cua type_text '{"text":"echo persona-ok"}' >>"$log" 2>&1 || note "type_text rc=$?"
  cua press_key '{"key":"return","scope":"desktop"}' >>"$log" 2>&1 || note "press_key rc=$?"
  python3 -c 'import time;time.sleep(1)'
  step first_command "$t"
  shot 03-first-command
  [ -n "$cli" ] && to 30 "$cli" computer-use status >"$out/cu-status.txt" 2>&1
  [ -n "$pid" ] && kill "$pid"
}

case "$mode" in
  probe) probe ;;
  p0) p0 ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
note "done"
