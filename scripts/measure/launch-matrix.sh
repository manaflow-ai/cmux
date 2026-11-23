#!/usr/bin/env bash
# One launch harness for ANY .app (Leo's cold-start tables: cmux NEXT against Claude, Codex, T3 Code, Edge, Chrome,
# Safari, Slack and Helium, every row from this one harness on one Mac). Run it on a Mac's console session:
#   scripts/measure/launch-matrix.sh --app PATH|nightly [--name NAME] [--scenario warm,cold-quit,...] [--reps N]
#     [--settle S] [--out DIR] [--profile auto|chromium|home|none] [--state-dir DIR] [--source DMG|ZIP|URL]
#   scripts/measure/launch-matrix.sh --app PATH --phase before|after [--out DIR]      (the reboot pair)
#   scripts/measure/launch-matrix.sh --app PATH --growth MINUTES [--out DIR]          (1 h / 8 h idle growth; nohup it)
#   scripts/measure/launch-matrix.sh --app PATH --seed N --state-dir DIR [--out DIR]   (make large-session's state)
# --app nightly: the cmux NEXT NIGHTLY the feed offers now (launch-fresh-install.sh's appcast), copied out of its DMG.
# Per launch the probe (launch-matrix.swift, built here with swiftc) prints LM-RUN; this adds app, scenario, rep, the
# 1-minute load and the arm's own fields, appends it to OUT/runs.jsonl, and at the end launch-matrix-summary.py prints
# one LM-TABLE per app x scenario (median, min, max, n of each number) and writes OUT/report.json. Times are ms from
# the LaunchServices open request: proc_start, window_on_screen, first_visible_frame, interactive (first accepted
# key), and the tree's resources at first interactive and after --settle S idle seconds (default 30). The probe's
# header says how each is taken and which grants it needs; LM-GRANTS says which it has.
# Scenarios (--scenario, comma separated, each --reps N, default 3; a priming launch first, not counted, whose
# profile is the template each later launch clones):
#   warm          relaunch 3 s after quitting a short run (the previous launch)
#   cold-quit     quit, wait 60 s (the condition launch-premain.sh found slow), launch; the file cache stays warm
#   evicted       as cold-quit, the bundle's files dropped from the page cache first: `sudo -n purge` when sudo allows
#                 it, else with no root the probe's evict (mmap + msync MS_INVALIDATE per file); evict_method and the
#                 resident pages before and after are in the row. The stand-in for the reboot arm (--phase)
#   first-install a fresh quarantined copy: --source (the vendor's DMG or zip; a URL is downloaded), else a zip of
#                 --app made here as the vendor's download stand-in; the file marked com.apple.quarantine as a
#                 browser download marks it (launch-fresh-install.sh's quarantine), the app copied out to a new path
#                 as a drag copies it (ditto), opened with an empty profile, Gatekeeper's prompt pressed Open at once
#                 by the console's CuaDriver (launch-fresh-install.sh's prompts; prompt_seen says whether one came)
#   update        a new unquarantined copy of the bundle put over the old path (what an in-place updater leaves),
#                 its first launch with the app's state kept (the template profile)
#   large-session launch with the pre-seeded heavy state --state-dir supplies (the caller seeds it: for cmux NEXT,
#                 launch-ready.sh's session=stress3 workspaces=120), cloned per launch, 3 s after the last quit;
#                 a Chromium browser is launched with --restore-last-session, so it reopens the seeded tabs
# --seed N --state-dir DIR: makes that state. home (cmux NEXT): the app opened on an empty profile and
# launch-ready-seed.py run on its socket for 3 windows and N workspaces in all (it quits with Keep Sessions).
# chromium: N local pages written under DIR/pages (no outside site), the app opened on an empty profile with them
# as N tabs, quit after 20 s, so the profile's last session holds N tabs. none (Safari): refused, it has no profile
# of its own to seed.
# first-install and update refuse an app on the sealed system volume (Safari): it has no copy to make.
# Isolation per launch (--profile, auto by default): chromium (Chrome, Edge, Helium and Electron apps:
# --user-data-dir and xbench.py's flags), home (cmux NEXT: an empty HOME with its own login keychain, as
# launch-premain.swift gives it), none (Safari and anything sandboxed: the build user's own state; this Mac's only
# user is the build user, so no person's state is touched or restored). warm, cold-quit and evicted keep one profile
# per scenario across their reps (a relaunch reopens its own state); the other arms clone one per launch.
# --phase before: one launch and quit, kern.boottime saved in OUT; then the caller reboots (never this script).
# --phase after: refuses (exit 3) unless kern.boottime changed since before and the boot is < 600 s old; then one
# measured launch, scenario after-reboot.
# --growth MINUTES: the app opened once and kept up; one LM-GROWTH line per minute (procs, threads, rss, footprint,
# cpu %, wakeups/s, disk read and written per minute) into OUT/growth.log as well as stdout.
# The probe skips an app already running (not ours to quit), and quits only what it opened.
set -uo pipefail

LM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# console, fresh_keychain, load1, quarantine, prompts, sweep_prompts, marker_write, marker_remove from the fresh
# install harness (which sources launch-premain.sh); neither main runs.
source "$LM_DIR/launch-fresh-install.sh"

lm_main() {
  cd "$LM_DIR/../.." || exit 3
  local app="" name="" scenarios="warm,cold-quit" reps=3 settle=30 out="" profile=auto state_dir="" source_file="" phase="" growth="" seed=""
  # cmux-ci passes a step's arguments as key=value (the bench's --arg): the same as --key value.
  local -a flags=()
  for a in "$@"; do
    case "$a" in
      app=*|name=*|scenario=*|reps=*|settle=*|out=*|profile=*|state-dir=*|source=*|phase=*|growth=*|seed=*) flags+=("--${a%%=*}" "${a#*=}") ;;
      *) flags+=("$a") ;;
    esac
  done
  set -- ${flags[@]+"${flags[@]}"}
  while (($#)); do
    case "$1" in
      --app) app="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --scenario) scenarios="$2"; shift 2 ;;
      --reps) reps="$2"; shift 2 ;;
      --settle) settle="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      --profile) profile="$2"; shift 2 ;;
      --state-dir) state_dir="$2"; shift 2 ;;
      --source) source_file="$2"; shift 2 ;;
      --phase) phase="$2"; shift 2 ;;
      --growth) growth="$2"; shift 2 ;;
      --seed) seed="$2"; shift 2 ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  [[ -n "$app" ]] || { echo "--app PATH|nightly is required" >&2; exit 2; }
  [[ "$reps" =~ ^[1-9][0-9]?$ ]] || { echo "--reps takes 1 to 99" >&2; exit 2; }
  [[ "$settle" =~ ^[0-9]+$ ]] || { echo "--settle takes seconds" >&2; exit 2; }
  [[ "$scenarios" =~ ^(warm|cold-quit|evicted|first-install|update|large-session)(,(warm|cold-quit|evicted|first-install|update|large-session))*$ ]] \
    || { echo "--scenario takes warm,cold-quit,evicted,first-install,update,large-session" >&2; exit 2; }
  [[ -z "$phase" || "$phase" == before || "$phase" == after ]] || { echo "--phase takes before or after" >&2; exit 2; }
  [[ -z "$growth" || "$growth" =~ ^[1-9][0-9]*$ ]] || { echo "--growth takes minutes" >&2; exit 2; }
  [[ -z "$seed" || ( "$seed" =~ ^[1-9][0-9]*$ && -n "$state_dir" ) ]] || { echo "--seed takes a count and needs --state-dir" >&2; exit 2; }
  [[ "$profile" =~ ^(auto|chromium|home|none)$ ]] || { echo "--profile takes auto, chromium, home, none" >&2; exit 2; }
  if [[ "$app" == nightly ]]; then
    name="${name:-cmux-next-nightly}"
  else
    [[ -d "$app" && "$app" == *.app ]] || { echo "--app $app is not an .app bundle" >&2; exit 2; }
    name="${name:-$(basename "$app" .app | tr ' ' '-' | tr '[:upper:]' '[:lower:]')}"
  fi
  OUT="${out:-$HOME/cold-start-matrix/out/$name}"
  mkdir -p "$OUT" && chmod 0777 "$OUT" && OUT="$(cd "$OUT" && pwd)"
  NAME="$name" SETTLE="$settle"
  echo "LM host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) load $(load1)"
  PROBE="$OUT/launch-matrix"
  if [[ ! -x "$PROBE" || "$LM_DIR/launch-matrix.swift" -nt "$PROBE" ]]; then
    xcrun swiftc -O -o "$PROBE" "$LM_DIR/launch-matrix.swift" >"$OUT/swiftc.log" 2>&1 || { echo "LM probe build failed"; cat "$OUT/swiftc.log"; exit 3; }
  fi
  cua_pick "$OUT"
  local grants; grants="$(console "$PROBE" grants 2>/dev/null | sed -n 's/^LM-GRANTS //p')"
  echo "LM-GRANTS {\"probe\": $grants, \"cuadriver\": \"$( [[ -x "$CUA" ]] && console "$CUA" permissions status 2>&1 | grep -E 'Accessibility|Screen Recording' | tr -s ' ' | tr '\n' ' ' || echo none)\"}"
  [[ "$app" == nightly ]] && { app="$(nightly_app)" || exit 3; }
  APP="$app"
  KIND="$profile"; [[ "$KIND" == auto ]] && KIND="$(profile_kind "$APP")"
  SYSTEM=0; [[ "$APP" == /System/* || "$(cd "$APP" && pwd -P)" == /System/* ]] && SYSTEM=1
  echo "LM app $NAME $APP version $(plist "$APP" CFBundleShortVersionString) profile=$KIND system=$SYSTEM"
  mkdir -p "$OUT/profiles"
  TEMPLATE="$OUT/profiles/template"

  if [[ "$phase" == after ]]; then phase_after; lm_summary; return $?; fi
  if [[ -n "$growth" ]]; then
    prime || exit 3
    local dir; dir="$(clone_profile growth)"
    # shellcheck disable=SC2046
    console "$PROBE" growth "$APP" growth "$growth" $(profile_args "$dir") 2>>"$OUT/probe.log" | tee -a "$OUT/growth.log"
    return 0
  fi
  prime || exit 3
  if [[ "$phase" == before ]]; then phase_before; return $?; fi
  if [[ -n "$seed" ]]; then seed_state "$state_dir" "$seed"; return $?; fi

  trap 'sweep_prompts Cancel exit; marker_remove' EXIT
  local list scenario rep rc=0; IFS=, read -r -a list <<<"$scenarios"
  for scenario in "${list[@]}"; do
    if [[ "$scenario" == first-install || "$scenario" == update ]] && ((SYSTEM)); then
      echo "LM-SKIP $NAME $scenario: a system app on the sealed volume has no copy to install or update"
      continue
    fi
    [[ "$scenario" == large-session && -z "$state_dir" ]] && { echo "LM-SKIP $NAME large-session: needs --state-dir"; continue; }
    [[ "$scenario" == first-install ]] && { PROMPT_BASELINE="$(prompts ids 2>/dev/null)"; marker_write; }
    for ((rep = 1; rep <= reps; rep++)); do
      quiet
      arm "$scenario" "$rep" "$state_dir" "$source_file" || rc=1
    done
  done
  lm_summary || rc=1
  return "$rc"
}

plist() { [[ -f "$1/Contents/Info.plist" ]] || return 0; /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

# profile_kind APP: chromium (a Chromium browser or an Electron app), home (cmux NEXT), else none.
profile_kind() {
  local id; id="$(plist "$1" CFBundleIdentifier)"
  if [[ "$id" == com.cmuxterm.* || -d "$1/Contents/Frameworks/CmuxNextApp.framework" ]]; then echo home; return; fi
  if compgen -G "$1/Contents/Frameworks/*Framework.framework" >/dev/null \
    && ls "$1/Contents/Frameworks" | grep -qE '^(Electron|Google Chrome|Microsoft Edge|Chromium|Helium|Brave Browser|Arc) ?.*Framework\.framework$'; then
    echo chromium; return
  fi
  echo none
}

# profile_args DIR: the probe's env=/-- arguments that put the app's state in DIR.
profile_args() {
  case "$KIND" in
    chromium) echo "-- --user-data-dir=$1/data --no-first-run --no-default-browser-check --password-store=basic --use-mock-keychain${RESTORE:+ --restore-last-session}${EXTRA_ARGS:+ $EXTRA_ARGS}" ;;
    home) echo "env=HOME=$1/h env=CFFIXED_USER_HOME=$1/h env=TMPDIR=$1/t/ env=CMUX_NEXT_SOCKET_PATH=/tmp/cmux-lm-$(id -u).sock env=CMUX_NEXT_SOCKET_MODE=allowAll" ;;
    none) echo "" ;;
  esac
}

# new_profile DIR: an empty profile (home: the dirs and a login keychain, as launch-premain's environment makes them).
new_profile() {
  mkdir -p "$1/data" "$1/t" "$1/h/Library/Preferences" "$1/h/Library/Application Support" "$1/h/Library/Caches"
  [[ "$KIND" == home ]] && fresh_keychain "$1/h"
  return 0
}

# clone_profile TAG: an APFS clone (cp -c) of the template into OUT/profiles/TAG, printed.
clone_profile() {
  local dir="$OUT/profiles/$1"
  rm -rf "$dir"
  if [[ "$KIND" == none ]]; then mkdir -p "$dir"; else cp -cR "$TEMPLATE" "$dir" 2>/dev/null || cp -R "$TEMPLATE" "$dir"; fi
  echo "$dir"
}

# nightly_app: the NIGHTLY's DMG from the feed, its app copied to OUT/apps (printed).
nightly_app() {
  local url
  url="$(curl -fsSL --proto '=https' --retry 3 -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  [[ -n "$url" ]] || { echo "LM no nightly DMG in the feed" >&2; return 1; }
  echo "LM dmg $url" >&2
  mkdir -p "$OUT/apps" "$OUT/mnt"
  if [[ ! -f "$OUT/apps/$(basename "$url").done" ]]; then
    curl -fsSL --proto '=https' --retry 3 -A cmux-launch-matrix/1 -o "$OUT/apps/nightly.dmg" "$url" || { echo "LM download failed" >&2; return 1; }
    hdiutil attach "$OUT/apps/nightly.dmg" -nobrowse -readonly -noautofsck -mountpoint "$OUT/mnt" >/dev/null || return 1
    local found; found="$(find "$OUT/mnt" -maxdepth 1 -name '*.app' | head -1)"
    rm -rf "$OUT/apps/nightly"; mkdir -p "$OUT/apps/nightly"
    ditto "$found" "$OUT/apps/nightly/$(basename "$found")"
    hdiutil detach "$OUT/mnt" >/dev/null || hdiutil detach -force "$OUT/mnt" >/dev/null
    rm -f "$OUT/apps/nightly.dmg"; touch "$OUT/apps/$(basename "$url").done"
  fi
  find "$OUT/apps/nightly" -maxdepth 1 -name '*.app' | head -1
}

# launch LABEL APPPATH PROFILE_DIR SETTLE: one probe run; prints its LM-RUN json (or an error object).
launch() {
  local line
  # shellcheck disable=SC2046
  # cmux NEXT (profile home) writes its launch marks to a FIFO the probe makes in the profile: the row's marks.
  local marks=""; [[ "$KIND" == home ]] && marks="$3/marks.fifo"
  line="$(console /usr/bin/env LM_CUA="$CUA" LM_MARKS_FIFO="$marks" "$PROBE" run "$2" "$1" "$4" $(profile_args "$3") 2>>"$OUT/probe.log" | grep '^LM-RUN ')"
  [[ -n "$line" ]] && echo "${line#LM-RUN }" || echo '{"error": "no result"}'
}

# gone APPPATH: wait (<= 60 s) until no process runs from the bundle.
gone() {
  local i
  for ((i = 0; i < 600; i++)); do
    ps -axo command= | LM_APP="$1/Contents/" awk 'index($0, ENVIRON["LM_APP"]) { n++ } END { exit n > 0 }' && return 0
    sleep 0.1
  done
}

# prime: the priming launch (not counted): the template profile every later launch clones, the app's first-run work
# done in it. Runs 10 s past the window so first-run jobs finish (xbench.py's template launch does the same).
prime() {
  [[ -d "$TEMPLATE" ]] && return 0
  new_profile "$TEMPLATE"
  local json; json="$(launch prime "$APP" "$TEMPLATE" 10)"
  echo "LM-PRIME $json"
  gone "$APP"
  [[ "$json" != *'"error"'* ]]
}

# record SCENARIO REP JSON EXTRA_JSON: the run with its context, to stdout and runs.jsonl.
record() {
  local json
  json="$(python3 -I -c '
import json, sys
r = json.loads(sys.argv[3]); r.update(json.loads(sys.argv[4] or "{}"))
r.update(app_name=sys.argv[5], scenario=sys.argv[1], rep=int(sys.argv[2]), load=float(sys.argv[6]), profile=sys.argv[7])
others = [int(p) for p in sys.argv[8].split()]
if others:  # a copy of the app this run did not start was up (on a shared Mac, Safari): the row says so
    r["other_instance_pids"] = others
print(json.dumps(r, sort_keys=True))' "$1" "$2" "$3" "${4:-{\}}" "$NAME" "$(load1)" "$KIND" "${LM_OTHERS:-}")"
  echo "LM-RUN $json"
  echo "$json" >>"$OUT/runs.jsonl"
}

# arm SCENARIO REP STATE_DIR SOURCE: one measured launch of the arm.
arm() {
  local scenario="$1" rep="$2" state="$3" src="$4" tag="$1-$2" dir extra="{}" target="$APP" json RESTORE=""
  case "$scenario" in
    warm|cold-quit|evicted)
      # A relaunch: one profile per scenario that every rep reopens, as a person's app reopens its own state. A fresh
      # clone per rep is a first open of a moved profile, not a relaunch (Chrome: window 4.7 s against 0.6 s on
      # cmux13s). Rep 1 follows a short run of its own; every later rep follows the previous rep.
      dir="$OUT/profiles/$scenario"
      if [[ "$rep" == 1 ]]; then dir="$(clone_profile "$scenario")"; launch "short-$tag" "$APP" "$dir" 1 >/dev/null; gone "$APP"; fi
      case "$scenario" in
        warm) sleep 3 ;;
        cold-quit) sleep 60 ;;
        evicted) sleep 60; extra="$(evict "$APP")" ;;
      esac ;;
    large-session)
      dir="$OUT/profiles/$tag"; rm -rf "$dir"; cp -cR "$state" "$dir" 2>/dev/null || cp -R "$state" "$dir"; sleep 3
      [[ "$KIND" == chromium ]] && RESTORE=1 ;;
    update)
      # Our own copy at a fixed path (never the installed bundle): launched once as the old copy, then each rep a new
      # unquarantined copy put over that path.
      local base="$OUT/apps/update" old
      old="$base/$(basename "$APP")"
      if [[ ! -d "$old" ]]; then
        mkdir -p "$base"; ditto "$APP" "$old"; xattr -dr com.apple.quarantine "$old" 2>/dev/null
        launch "update-old" "$old" "$(clone_profile update-old)" 1 >/dev/null; gone "$old"
      fi
      ditto "$APP" "$old.new" && xattr -dr com.apple.quarantine "$old.new" 2>/dev/null
      rm -rf "$old" && mv "$old.new" "$old"
      target="$old" dir="$(clone_profile "$tag")"; sleep 3 ;;
    first-install)
      target="$(install_copy "$tag" "$src")" || { record "$scenario" "$rep" '{"error": "no quarantined copy"}'; return 1; }
      dir="$OUT/profiles/$tag"; rm -rf "$dir"; new_profile "$dir" ;;
  esac
  local presser=""
  if [[ "$scenario" == first-install ]]; then
    # Gatekeeper's prompt: pressed Open as soon as it shows (launch-fresh-install-prompts.py through CuaDriver), so a
    # person's reading time is not in the row. The prompt sits before the window: window_on_screen includes it.
    ( for ((i = 0; i < 120; i++)); do sweep_prompts Open "$tag" >>"$OUT/prompts-$tag.log" 2>&1; sleep 0.5; done ) &
    presser=$!
  fi
  # Main processes of this bundle already up that this run did not start (left alone; named in the row).
  LM_OTHERS="$(pgrep -f "$target/Contents/MacOS/" 2>/dev/null | tr '\n' ' ')"
  json="$(launch "$tag" "$target" "$dir" "$SETTLE")"
  if [[ -n "$presser" ]]; then
    kill "$presser" 2>/dev/null; wait "$presser" 2>/dev/null
    local seen=false; grep -q 'LF-PROMPT' "$OUT/prompts-$tag.log" 2>/dev/null && seen=true
    extra="{\"prompt_seen\": $seen, \"quarantine\": \"$(qattr "$target" | cut -c1-40)\", \"ran_from\": \"$target\"}"
    sweep_prompts Cancel "after $tag"
  fi
  gone "$target"
  record "$scenario" "$rep" "$json" "$extra"
  [[ "$scenario" == first-install ]] && rm -rf "$OUT/fi/$tag"
  [[ "$json" != *'"error"'* ]]
}

# evict APP: the bundle out of the page cache; prints the row's evict fields.
evict() {
  if sudo -n -l /usr/sbin/purge >/dev/null 2>&1 && sudo -n /usr/sbin/purge 2>/dev/null; then
    echo '{"evict_method": "purge"}'; return
  fi
  local line; line="$("$PROBE" evict "$1" | sed -n 's/^LM-EVICT //p')"
  python3 -I -c 'import json,sys; e = json.loads(sys.argv[1] or "{}"); print(json.dumps({"evict_method": "msync-invalidate", "evict": e}))' "$line"
}

# install_copy TAG SOURCE: a quarantined download of the app (SOURCE, else a zip of APP made here), copied to a new
# path as a drag does; prints the copied app's path.
install_copy() {
  local tag="$1" src="$2" dir="$OUT/fi/$tag" file found
  rm -rf "$dir"; mkdir -p "$dir/dl" "$dir/Applications" "$dir/mnt"
  if [[ "$src" == https://* ]]; then
    [[ -f "$OUT/fi/source.download" ]] || curl -fsSL --proto '=https' --retry 3 -A cmux-launch-matrix/1 -o "$OUT/fi/source.download" "$src" || return 1
    src="$OUT/fi/source.download"
  fi
  if [[ -z "$src" ]]; then
    [[ -f "$OUT/fi/vendor.zip" ]] || ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/fi/vendor.zip" || return 1
    src="$OUT/fi/vendor.zip"
  fi
  file="$dir/dl/$(basename "$src")"
  cp "$src" "$file" && quarantine "$file"
  if [[ "$file" == *.pkg ]]; then
    # An installer package: Installer copies the app out of the payload and the app carries no quarantine (the pkg
    # was the file Gatekeeper judged); expanded here without root, the app copied out the same way.
    pkgutil --expand-full "$file" "$dir/pkg" >/dev/null || return 1
    found="$(find "$dir/pkg" -maxdepth 5 -name '*.app' -type d | head -1)"
    [[ -n "$found" ]] || return 1
    ditto "$found" "$dir/Applications/$(basename "$found")" && rm -rf "$dir/pkg"
    echo "$dir/Applications/$(basename "$found")"; return 0
  elif hdiutil imageinfo "$file" >/dev/null 2>&1; then
    hdiutil attach "$file" -nobrowse -readonly -noautofsck -mountpoint "$dir/mnt" >/dev/null || return 1
    found="$(find "$dir/mnt" -maxdepth 1 -name '*.app' | head -1)"
    ditto "$found" "$dir/Applications/$(basename "$found")"
    hdiutil detach "$dir/mnt" >/dev/null || hdiutil detach -force "$dir/mnt" >/dev/null
  else
    # Archive Utility's way: the zip's quarantine onto every file it extracts.
    ditto -x -k "$file" "$dir/Applications" || return 1
  fi
  found="$(find "$dir/Applications" -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "$found" ]] || return 1
  [[ "$(qattr "$found")" == none ]] && find "$found" -exec xattr -w com.apple.quarantine "$(xattr -p com.apple.quarantine "$file")" {} + 2>/dev/null
  echo "$found"
}

boot_time() { sysctl -n kern.boottime | sed -n 's/.*sec = \([0-9]*\),.*/\1/p'; }

# quiet: before each launch, wait (at most LM_QUIET_MAX_S, default 300 s) until the 1-minute load is at most
# LM_QUIET_LOAD (default 4), so a busy host does not set the row; the row's load says what it got.
quiet() {
  local i max="${LM_QUIET_MAX_S:-300}"
  for ((i = 0; i < max / 5; i++)); do
    awk -v l="$(load1)" -v m="${LM_QUIET_LOAD:-4}" 'BEGIN { exit !(l <= m) }' && return 0
    sleep 5
  done
  echo "LM-QUIET load $(load1) still above ${LM_QUIET_LOAD:-4} after ${max} s; launching anyway"
}

# seed_state DIR N: large-session's state (the header's --seed). Prints LM-SEED.
seed_state() {
  local dir="$1" n="$2"
  [[ "$KIND" == none ]] && { echo "LM-SEED {\"error\": \"profile none: no profile of its own to seed\"}"; return 3; }
  [[ -e "$dir" ]] && { echo "LM-SEED {\"error\": \"$dir exists; seed a new dir\"}"; return 3; }
  new_profile "$dir"
  if [[ "$KIND" == chromium ]]; then
    local i urls=""
    mkdir -p "$dir/pages"
    for ((i = 1; i <= n; i++)); do
      printf '<!doctype html><title>Page %d</title><h1>Page %d</h1><p>%s</p>\n' "$i" "$i" "$(printf 'local text %.0s' {1..200})" >"$dir/pages/$i.html"
      urls+=" file://$dir/pages/$i.html"
    done
    EXTRA_ARGS="${urls# }" launch seed "$APP" "$dir" 20 >"$OUT/seed.json"; gone "$APP"
    local tabs; tabs="$(ls "$dir/data/Default/Sessions" 2>/dev/null | wc -l | tr -d ' ')"
    echo "LM-SEED {\"kind\": \"chromium\", \"tabs\": $n, \"session_files\": $tabs, \"run\": $(cat "$OUT/seed.json")}"
    [[ "$tabs" -gt 0 ]]
  else
    local sock="/tmp/cmux-lm-$(id -u).sock" rc i
    rm -f "$sock"  # this harness's own socket path, left by an earlier run of ours
    launch seed "$APP" "$dir" 600 >"$OUT/seed.json" &
    local held=$!
    for ((i = 0; i < 600; i++)); do [[ -S "$sock" ]] && break; sleep 0.1; done
    quiet
    nice -n 10 python3 -I "$LM_DIR/launch-ready-seed.py" "$sock" --windows 3 --total-workspaces "$n" | tee "$OUT/seed.log"; rc=${PIPESTATUS[0]}
    wait "$held"; gone "$APP"
    echo "LM-SEED {\"kind\": \"home\", \"workspaces\": $n, \"rc\": $rc}"
    return "$rc"
  fi
}

phase_before() {
  local json; json="$(launch before "$APP" "$(clone_profile before)" 2)"
  gone "$APP"
  python3 -I -c 'import json,sys; json.dump({"boottime": int(sys.argv[1]), "app": sys.argv[2]}, open(sys.argv[3], "w"))' \
    "$(boot_time)" "$APP" "$OUT/phase-before.json"
  echo "LM-PHASE before $json"
  echo "LM-PHASE before done: reboot now (the caller's step), then --phase after within 600 s of the boot"
}

phase_after() {
  [[ -f "$OUT/phase-before.json" ]] || { echo "LM-FAIL no before phase in $OUT"; exit 3; }
  local before age; before="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["boottime"])' "$OUT/phase-before.json")"
  [[ "$(boot_time)" != "$before" ]] || { echo "LM-FAIL not rebooted: kern.boottime is still the before phase's"; exit 3; }
  age=$(($(date +%s) - $(boot_time)))
  ((age < 600)) || { echo "LM-FAIL booted ${age}s ago (over 600 s): not the first launch after a reboot"; exit 3; }
  local json; json="$(launch after-reboot "$APP" "$(clone_profile after-reboot)" "$SETTLE")"
  gone "$APP"
  record after-reboot 1 "$json" "{\"boot_age_s\": $age}"
}

lm_summary() { python3 -I "$LM_DIR/launch-matrix-summary.py" "$OUT/runs.jsonl" "$OUT/report.json"; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then lm_main "$@"; fi
