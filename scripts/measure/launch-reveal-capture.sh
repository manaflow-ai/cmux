#!/usr/bin/env bash
# What another macOS app shows from the Dock click until real content, as design references for cmux NEXT's own launch
# reveal (cmux-design-references launch-reveal/). It installs each app from the official download URL it is given into a
# temp dir, launches it through LaunchServices as a Dock click does, and records the console session's screen from before
# the launch until the content settles: cold (no state of the app on this Mac) and relaunch, in light and dark
# appearance. No login: a logged-out launch is what a first launch shows.
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/launch-reveal-capture.sh --ref <sha> --arg=app=NAME=https://official/download.dmg \
#     [--arg=app=NAME2=https://...] [--arg=appearance=light,dark] [--arg=seconds=10] [--arg=winshots=1] \
#     --artifact .build/launch-reveal/report.tgz --timeout 3600
#   app=NAME=URL          one app (repeatable): NAME is a lowercase label for the files, URL its DMG
#   appearance=light,dark which appearances (default both)
#   seconds=N             recorded seconds from the launch (4 to 30, default 10)
#   winshots=1            also a window-only still (screencapture -l) in a loop of about 10 a second, for a noisy display
# Per app and appearance: the app's own state dirs (the ones named by its bundle id that do not exist yet) are removed,
# a cold launch is recorded, the app is quit, it is launched again (relaunch) and recorded, and it is quit. The
# artifact holds <name>-<appearance>-<cold|relaunch>.mov, its LRC-WIN window log (epoch ms, window id, bounds, alpha)
# and frames/ when ffmpeg is installed; stills and strips are cut from the .mov off the Mac.
# Only the app this script launched is quit (by PID), only its temp dir and the state dirs it made are removed, and the
# appearance is put back as found. Screen Recording must be granted to the step's process: LRC prints what it finds.
set -uo pipefail

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

log() { echo "LRC $*"; }

TMP=""
OUT=""
APP_PID=""
REC_PID=""
WATCH_PID=""
ORIG_DARK=""
MOUNT=""
CREATED_STATE=()

restore_and_clean() {
  # Only what this script started: the app by PID, the recorder, the watcher, the mount, the appearance, the temp dir.
  local p
  for p in "$APP_PID" "$REC_PID" "$WATCH_PID"; do
    [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null
  done
  [[ -n "$MOUNT" && -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null
  if [[ -n "$ORIG_DARK" ]]; then
    set_appearance "$ORIG_DARK" || true
  fi
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
}

# Appearance: "dark" or "light". System Events changes it live; the defaults key is the fallback.
set_appearance() {
  local want="$1" flag=false
  [[ "$want" == dark ]] && flag=true
  osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $flag" >/dev/null 2>&1 \
    || { if [[ "$want" == dark ]]; then defaults write -g AppleInterfaceStyle Dark; else defaults delete -g AppleInterfaceStyle 2>/dev/null; fi; }
  # Until the global default reads the wanted appearance, 10 s.
  local got=light i
  for i in $(seq 1 100); do
    got=light
    [[ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" == Dark ]] && got=dark
    [[ "$got" == "$want" ]] && break
    sleep 0.1
  done
  [[ "$got" == "$want" ]] || log "WARN appearance wanted $want, reads $got"
  return 0
}

current_appearance() {
  [[ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" == Dark ]] && echo dark || echo light
}

download_app() {   # NAME URL -> prints the .app path under $TMP/apps (its only stdout: the caller captures it)
  local name="$1" url="$2" dmg="$TMP/$1.dmg" mnt="$TMP/mnt-$1" app
  exec 3>&1 1>&2
  log "DOWNLOAD $name $url"
  curl -fsSL --retry 3 --max-time 600 -o "$dmg" "$url" || { log "FAIL download $name"; return 1; }
  log "DOWNLOAD $name $(stat -f %z "$dmg") bytes sha256 $(shasum -a 256 "$dmg" | cut -d' ' -f1)"
  mkdir -p "$mnt" "$TMP/apps"
  MOUNT="$mnt"
  hdiutil attach "$dmg" -nobrowse -readonly -noverify -mountpoint "$mnt" -quiet || { log "FAIL attach $name"; return 1; }
  app="$(find "$mnt" -maxdepth 2 -name '*.app' -print -quit)"
  [[ -n "$app" ]] || { log "FAIL no .app in $name dmg"; return 1; }
  ditto "$app" "$TMP/apps/$(basename "$app")" || { log "FAIL ditto $name"; return 1; }
  hdiutil detach "$mnt" -quiet -force; MOUNT=""
  xattr -dr com.apple.quarantine "$TMP/apps/$(basename "$app")" 2>/dev/null
  echo "$TMP/apps/$(basename "$app")" >&3
}

# The per-user state a launch makes, named by the bundle id and the app name: removed first (cold) when absent, and
# again at the end only when this script found none.
state_paths() {   # BUNDLE_ID APP_NAME
  local b="$1" n="$2" h="$HOME/Library"
  printf '%s\n' "$h/Application Support/$n" "$h/Caches/$b" "$h/Preferences/$b.plist" "$h/Saved Application State/$b.savedState" \
    "$h/HTTPStorages/$b" "$h/HTTPStorages/$b.binarycookies" "$h/WebKit/$b" "$h/Containers/$b" "$h/Logs/$n"
}

launch_and_record() {   # APP_PATH NAME APPEARANCE MODE
  local app="$1" name="$2" appearance="$3" mode="$4" base="$OUT/$2-$3-$4"
  local t_rec t_open t_end shots_pid=""
  APP_PID=""
  log "RUN $name $appearance $mode $(date +%H:%M:%S)"
  screencapture -x "$base-before.png" 2>/dev/null
  # -V N records N seconds then exits (SIGINT does not reach a background job in a script).
  screencapture -x -v -V $((SECONDS_REC + 3)) "$base.mov" 2>"$base.rec.log" &
  REC_PID=$!
  sleep 1.0
  t_rec="$(now_ms)"
  t_open="$(now_ms)"
  open "$app" || { log "FAIL open $name"; return 1; }
  log "OPEN $name $mode epoch_ms=$t_open rec_started_ms=$t_rec"
  local i
  for i in $(seq 1 100); do
    APP_PID="$("$PROBE" pid "$app" | head -1)"
    [[ -n "$APP_PID" ]] && break
    sleep 0.05
  done
  [[ -n "$APP_PID" ]] || { log "FAIL $name has no process"; return 1; }
  log "PID $name $APP_PID"
  "$PROBE" windows "$APP_PID" "$SECONDS_REC" >"$base.windows.log" 2>&1 &
  WATCH_PID=$!
  if [[ "$WINSHOTS" == 1 ]]; then
    (
      mkdir -p "$base-winshots"
      local end=$(( $(now_ms) + SECONDS_REC * 1000 )) wid
      while [[ "$(now_ms)" -lt "$end" ]]; do
        wid="$(tail -1 "$base.windows.log" 2>/dev/null | awk '/^LRC-WIN/ {print $2}')"
        [[ -n "$wid" ]] && screencapture -x -o -l "$wid" "$base-winshots/$(now_ms).png" 2>/dev/null
      done
    ) &
    shots_pid=$!
  fi
  sleep "$SECONDS_REC"  # sleep-ok: the recording window itself
  wait "$WATCH_PID" 2>/dev/null; WATCH_PID=""
  [[ -n "$shots_pid" ]] && wait "$shots_pid" 2>/dev/null
  t_end="$(now_ms)"
  wait "$REC_PID" 2>/dev/null; REC_PID=""
  log "DONE $name $appearance $mode ended_ms=$t_end mov=$(stat -f %z "$base.mov" 2>/dev/null || echo missing) bytes"
  [[ -s "$base.mov" ]] || { log "WARN no recording: $(head -c 300 "$base.rec.log")"; }
  quit_app "$app"
  return 0
}

quit_app() {   # APP_PATH
  local i app="$1"
  [[ -n "$APP_PID" ]] || return 0
  kill -TERM "$APP_PID" 2>/dev/null
  for i in $(seq 1 100); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$APP_PID" 2>/dev/null; then log "KILL $APP_PID after 10 s"; kill -KILL "$APP_PID" 2>/dev/null; fi
  APP_PID=""
  # Until LaunchServices no longer lists the app as running (the next run's open must start a new one), 10 s.
  for i in $(seq 1 100); do [[ -z "$("$PROBE" pid "$app" | head -1)" ]] && break; sleep 0.1; done
  [[ -z "$("$PROBE" pid "$app" | head -1)" ]] || log "WARN $app still listed as running 10 s after it exited"
}

main() {
  cd "$(dirname "$0")/../.." || exit 3
  OUT="$PWD/.build/launch-reveal"
  local appearances="light,dark" arg names=() urls=() entry i
  SECONDS_REC=10; WINSHOTS=0
  rm -rf "$OUT" && mkdir -p "$OUT" && chmod 0777 "$OUT"
  for arg in "$@"; do
    case "$arg" in
      app=[a-z]*=https://*) entry="${arg#app=}"; names+=("${entry%%=*}"); urls+=("${entry#*=}") ;;
      appearance=*) appearances="${arg#appearance=}" ;;
      seconds=*) SECONDS_REC="${arg#seconds=}" ;;
      winshots=0|winshots=1) WINSHOTS="${arg#winshots=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$SECONDS_REC" =~ ^([4-9]|[12][0-9]|30)$ ]] || { echo "seconds= must be 4 to 30" >&2; exit 2; }
  [[ ${#names[@]} -ge 1 ]] || { echo "at least one app=NAME=https://URL" >&2; exit 2; }
  [[ "$appearances" =~ ^(light|dark)(,(light|dark))*$ ]] || { echo "appearance= takes light and dark" >&2; exit 2; }
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/launch-reveal.XXXXXX")" || exit 3
  trap restore_and_clean EXIT
  log "host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  log "display $(system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|UI Looks' | tr -s ' ' | tr '\n' ';')"
  ORIG_DARK="$(current_appearance)"
  log "appearance at start: $ORIG_DARK"
  xcrun swiftc -O -o "$TMP/probe" scripts/measure/launch-reveal-probe.swift >"$TMP/swiftc.log" 2>&1 \
    || { log "FAIL probe build"; cat "$TMP/swiftc.log"; exit 3; }
  PROBE="$TMP/probe"
  local granted; granted="$("$PROBE" screen-access)"
  log "screen recording access for this process: $granted"
  local rc=0 app appearance mode bundle name path url paths p existed
  for i in "${!names[@]}"; do
    app="${names[$i]}"; url="${urls[$i]}"
    path="$(download_app "$app" "$url")" || { rc=1; continue; }
    bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist")"
    name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$path/Contents/Info.plist")"
    log "APP $app $path bundle=$bundle name=$name version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$path/Contents/Info.plist")"
    for appearance in ${appearances//,/ }; do
      set_appearance "$appearance"
      # Cold: remove only state dirs that did not exist before this script (it never touches a person's data).
      CREATED_STATE=()
      existed=0
      while IFS= read -r p; do
        if [[ -e "$p" ]]; then existed=1; log "STATE $app existed before: $p"; fi
      done < <(state_paths "$bundle" "$name")
      [[ "$existed" == 1 ]] && log "WARN $app has state on this Mac: its first run below is a relaunch, not cold"
      for mode in cold relaunch; do
        launch_and_record "$path" "$app" "$appearance" "$mode" || rc=1
      done
      if [[ "$existed" == 0 ]]; then
        while IFS= read -r p; do [[ -e "$p" ]] && rm -rf "$p" && log "CLEAN $p"; done < <(state_paths "$bundle" "$name")
      fi
    done
    rm -rf "$path"
  done
  if command -v ffmpeg >/dev/null 2>&1; then
    local mov
    for mov in "$OUT"/*.mov; do
      [[ -s "$mov" ]] || continue
      mkdir -p "${mov%.mov}-frames"
      ffmpeg -v error -i "$mov" -vf fps=10 "${mov%.mov}-frames/f_%04d.png" 2>/dev/null
    done
  fi
  tar -czf "$OUT/report.tgz" -C "$OUT" . 2>/dev/null
  log "ARTIFACT $OUT/report.tgz $(stat -f %z "$OUT/report.tgz") bytes"
  exit "$rc"
}

main "$@"
