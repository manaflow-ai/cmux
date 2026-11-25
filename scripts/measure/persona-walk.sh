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
note() { printf '%s %s\n' "$(date -u +%H:%M:%S.%3N 2>/dev/null || date -u +%H:%M:%S)" "$*" | tee -a "$log"; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
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
    echo "--- computer-use status"; timeout 30 cmux computer-use status 2>&1 | head -30
    echo "--- computer-use doctor"; timeout 60 cmux computer-use doctor 2>&1 | head -60
    echo "--- screencapture"; timeout 20 screencapture -x "$out/shots/probe-screen.png" && echo ok
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

p0() {
  probe
  install_nightly || return 1
  local t0 pid
  t0=$(now_ms)
  open -n -a "$APP" --args 2>>"$log"
  for _ in $(seq 1 120); do
    if timeout 10 cmux computer-use call list_windows --args '{}' 2>/dev/null | grep -qi cmux; then break; fi
    python3 -c 'import time;time.sleep(0.5)'
  done
  note "first window after $(( $(now_ms) - t0 )) ms"
  timeout 20 screencapture -x "$out/shots/p0-first-window.png"
  timeout 30 cmux computer-use call list_windows --args '{}' >"$out/windows.json" 2>&1
  pid=$(pgrep -nf "$APP/Contents/MacOS" || true)
  [ -n "$pid" ] && kill "$pid"
}

case "$mode" in
  probe) probe ;;
  p0) p0 ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
note "done"
