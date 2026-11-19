#!/usr/bin/env bash
# How fast cmux NEXT comes back when it was kept in the background, against today's relaunch (Leo, 2026-11-17, on
# launch numbers: "how can we improve those? startup in background maybe?"; Leo-Ask-Trace: ask-b2b0f899c1). Timed
# from outside the app on a fleet Mac's console session:
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/background-ready.sh --ref <sha> [--arg=dmg=nightly|build] [--arg=head=<sha>] \
#     [--arg=runs=5] [--arg=arms=cold,hide,close] [--arg=idle=600] [--arg=settle=6] [--arg=setting=afterQuit] \
#     --artifact .build/background-ready/report.tgz --timeout 7200
#   dmg=nightly  the newest build the NIGHTLY feed offers (default)
#   dmg=build    a tagged Release app built as launch-ready.sh builds one (nightly-fresh-launch.sh's build_dmg)
#   head=SHA     with dmg=build: build SHA instead of this checkout (a pull request's head: the controller runs this
#                script only at a commit of feat-cmux-next)
#   runs=N       measured shows per arm (1 to 10, default 5), after one priming launch
#   arms=LIST    from cold, hide, close, quit (default cold,hide,close), run one after the other:
#     cold   today's relaunch: SIGTERM ("Quit, keep sessions", as launch-ready.sh), then a new instance
#     hide   NSRunningApplication.hide() (Cmd-H) until no window is on screen, then the app is opened again
#     close  every window closed (`action.run closeWindow` on the app's socket) and the app's activation policy
#            .accessory (app.hideDockIconWithoutWindows: no Dock icon), then opened again
#     quit   NSRunningApplication.terminate(), a quit Apple event (an interactive quit). A process that exits makes
#            the round a cold relaunch (`exited: true`: today's nightly); one that stays alive with no window is
#            opened again. For a head build with the background setting: see setting=
#   idle=S       the idle-cost window (default 600; 0 skips), once per arm, 60 s after its first background state
#                (cold: with its window shown, and its quit's leftovers for up to 60 s): BR-IDLE
#   settle=S     seconds each show stays up before the next round (default 6), as launch-ready's settle
#   setting=afterQuit  the quit arm's home config gets app.backgroundReady "afterQuit" (a head build's setting:
#                Quit leaves the process hidden). The other arms keep the default, so they stay today's behaviour
# "Opened again" is what a Dock click or `open` of the running app does: NSWorkspace.openApplication with
# createsNewApplicationInstance false, activates true (applicationShouldHandleReopen). scripts/measure/
# background-ready.swift drives one arm in one process, holding the marks FIFO for the whole arm (the app opens it
# once): BR-RUN ARM {json} per show, in ms since the open request (window_on_screen, active; frame_committed and
# usable from the app's marks: a cold launch's first_window_frame_committed and window_usable, a warm show's last
# reopen.first_frame_committed and reopen.window_usable, which builds without them do not write). Each row carries
# load_1m, exited, front and the background step's own times. BR-MEDIAN ARM per arm, BR-IDLE ARM per idle window
# (scripts/measure/background-ready-idle.py on scripts/perf-bench/procs.py: rss, phys_footprint, CPU, wakeups/s, mW per
# process kind; open files and sockets per pid; pmset assertions of those pids), BR-FAIL for a failed round.
# Each arm has its own copy of the app, its own home and config file (CMUX_NEXT_CONFIG_FILE) and its own defaults,
# through launch-ready.sh's side_defaults (sourced, not copied): a launch snapshot path outside the arm's home after
# the arm is BR-CROSS-ARM, and the step fails. Every process of an arm's copy is stopped by pid when the arm ends,
# the hidden app too. A launch A/B at the default setting is launch-ready.sh's base=/head=, unchanged.
# Not yet: front=chat (a seeded agent chat in front): relaunch_restore_check.py's chat seeding needs debug.* commands.
set -uo pipefail

# launch-ready.sh, sourced, only defines its functions: side_defaults, defaults_aside, defaults_restore, quiesce,
# load_1m. It sets no state of its own but LR_ASIDE (set below).
source "$(dirname "${BASH_SOURCE[0]}")/launch-ready.sh" || exit 3

br_main() {
  cd "$(dirname "$0")/../.." || exit 3
  local out="$PWD/.build/background-ready" dmg=nightly headsha="" runs=5 arms="cold,hide,close" idle=600 settle=6 setting=""
  local arg rc=0 arm
  for arg in "$@"; do
    case "$arg" in
      dmg=nightly|dmg=build) dmg="${arg#dmg=}" ;;
      head=*) headsha="${arg#head=}" ;;
      runs=*) runs="${arg#runs=}" ;;
      arms=*) arms="${arg#arms=}" ;;
      idle=*) idle="${arg#idle=}" ;;
      settle=*) settle="${arg#settle=}" ;;
      setting=afterQuit) setting=afterQuit ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$runs" =~ ^([1-9]|10)$ ]] || { echo "runs= must be 1 to 10" >&2; exit 2; }
  [[ "$idle" =~ ^[0-9]+$ && "$idle" -le 3600 ]] || { echo "idle= takes 0 to 3600 seconds" >&2; exit 2; }
  [[ "$settle" =~ ^[0-9]+$ && "$settle" -ge 1 && "$settle" -le 120 ]] || { echo "settle= takes 1 to 120 seconds" >&2; exit 2; }
  [[ -z "$headsha" || ( "$dmg" == build && "$headsha" =~ ^[0-9a-f]{40}$ ) ]] || { echo "head= takes a 40-hex commit, with dmg=build" >&2; exit 2; }
  local list=() seen=" "
  IFS=, read -r -a list <<<"$arms"
  [[ ${#list[@]} -gt 0 ]] || { echo "arms= names at least one of cold, hide, close, quit" >&2; exit 2; }
  for arm in ${list[@]+"${list[@]}"}; do
    case "$arm" in cold|hide|close|quit) ;; *) echo "arms= takes cold, hide, close, quit: not $arm" >&2; exit 2 ;; esac
    case "$seen" in *" $arm "*) echo "arms= names $arm twice" >&2; exit 2 ;; esac
    seen="$seen$arm "
  done
  [[ -z "$setting" || "$seen" == *" quit "* ]] || { echo "setting= is the quit arm's: add quit to arms=" >&2; exit 2; }
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  # Each arm's control socket: a socket path must fit sun_path (104 bytes with its NUL), as in launch-ready.sh.
  BR_SOCKETS="$(mktemp -d /tmp/br.XXXXXX)" && chmod 0777 "$BR_SOCKETS" || exit 3
  # shellcheck disable=SC2034 # launch-ready.sh's defaults_aside and defaults_restore read it
  LR_ASIDE="" BR_STARTED=""
  trap 'br_stop_all "$out"; rm -rf "$BR_SOCKETS"; defaults_restore "$out" || exit 4' EXIT
  echo "BR host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  echo "BR arms ${list[*]} runs $runs idle $idle settle $settle setting ${setting:-default}"
  # Everything this run reads from the checkout is compiled or copied now: dmg=build checks out another commit.
  xcrun swiftc -O -o "$out/background-ready" scripts/measure/background-ready.swift >"$out/swiftc.log" 2>&1 \
    || { echo "BR driver build failed"; cat "$out/swiftc.log"; exit 3; }
  cp scripts/measure/background-ready-idle.py "$out/idle.py"
  cp scripts/perf-bench/procs.py "$out/procs.py"
  cp scripts/measure/launch-ready-defaults.py "$out/defaults.py"
  cp scripts/ci/fresh_home_launch_smoke.py "$out/fresh_home_launch_smoke.py"
  br_get_dmg "$out" "$dmg" "$headsha" || exit 3
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  local mount="$out/mnt" found
  mkdir -p "$mount"
  hdiutil attach "$out/head.dmg" -nobrowse -readonly -mountpoint "$mount" >/dev/null || { echo "BR attach failed"; exit 3; }
  found="$(find "$mount" -maxdepth 1 -name '*.app' | head -1)"
  for arm in ${list[@]+"${list[@]}"}; do
    mkdir -p "$out/$arm" && ditto "$found" "$out/$arm/$(basename "$found")" || { hdiutil detach -force "$mount" >/dev/null; exit 3; }
  done
  hdiutil detach "$mount" >/dev/null || hdiutil detach -force "$mount" >/dev/null
  echo "BR app $(basename "$found") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$out/${list[0]}/$(basename "$found")/Contents/Info.plist" 2>/dev/null)"
  for arm in ${list[@]+"${list[@]}"}; do
    br_arm "$out" "$arm" "$runs" "$settle" "$idle" "$([[ "$arm" == quit ]] && echo "$setting")" || rc=1
  done
  touch "$out/runs.jsonl" "$out/idle.jsonl"
  python3 -I - "$out/runs.jsonl" <<'PY'
import json, statistics, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
for arm in dict.fromkeys(r["arm"] for r in rows):
    measured = [r for r in rows if r["arm"] == arm and str(r.get("label", "")).startswith("run")]
    done = [r for r in measured if r.get("window_on_screen") is not None and not r.get("error")]
    loads = [r["load_1m"] for r in done if r.get("load_1m") is not None]
    med = {"n": len(done), "of": len(measured), "exited": sum(bool(r.get("exited")) for r in measured),
           "max_load_1m": max(loads) if loads else None}
    for key in ("window_on_screen", "active", "frame_committed", "usable", "request_to_start", "hidden_s"):
        vals = [r[key] for r in done if r.get(key) is not None]
        med[key] = round(statistics.median(vals), 1) if vals else None
    reached = [r["background"]["reached_ms"] for r in done if isinstance(r.get("background"), dict) and r["background"].get("reached_ms") is not None]
    med["background_reached_ms"] = round(statistics.median(reached), 1) if reached else None
    names = dict.fromkeys(n for r in done for n in (r.get("reopen_since_request") or {}))
    for name in sorted(names):
        vals = [r["reopen_since_request"][name] for r in done if name in (r.get("reopen_since_request") or {})]
        med[name] = round(statistics.median(vals), 1)
    judged = [r for r in measured if "reopened" in r]
    med["reopened"] = f"{sum(bool(r['reopened']) for r in judged)}/{len(judged)}"
    print("BR-MEDIAN", arm, json.dumps(med, sort_keys=True), flush=True)
PY
  # The rows and logs only: an arm's home holds its app data (and Chromium's code-sign clone under its TMPDIR).
  (cd "$out" && tar -czf "$out.tgz" ./*.jsonl ./*.log ./home-*/defaults.plist 2>/dev/null) ; mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

# br_get_dmg OUT DMG HEAD: OUT/head.dmg, the NIGHTLY feed's newest or (dmg=build) HEAD built as launch-ready.sh builds
# its head: nightly-fresh-launch.sh's build_dmg, sourced from a file without its main.
br_get_dmg() {
  local out="$1" dmg="$2" headsha="$3" here head rc
  if [[ "$dmg" == build ]]; then
    sed '/^main "\$@"; exit \$?$/d' scripts/measure/nightly-fresh-launch.sh >"$out/nightly-fresh-launch-lib.sh"
    source "$out/nightly-fresh-launch-lib.sh"
    declare -F build_dmg >/dev/null || { echo "BR build_dmg missing from nightly-fresh-launch.sh"; return 3; }
    cp scripts/cmux-next/resolve-acpmux.sh "$out/resolve-acpmux.sh" && export NFL_RESOLVE_ACPMUX="$out/resolve-acpmux.sh"
    here="$(git rev-parse HEAD)"
    head="${headsha:-$here}"
    git cat-file -e "$head^{commit}" 2>/dev/null \
      || git fetch --quiet https://github.com/manaflow-ai/cmux.git "$head" || { echo "BR cannot fetch $head"; return 3; }
    git -c advice.detachedHead=false checkout --quiet --detach "$head" || return 3
    build_dmg "$out" head release; rc=$?
    git -c advice.detachedHead=false checkout --quiet --detach "$here" || return 3
    [[ $rc == 0 ]] || return "$rc"
    echo "BR build $head"
    return 0
  fi
  dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
    | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  [[ "$dmg" == https://* ]] || { echo "BR no nightly DMG in the feed"; return 3; }
  echo "BR dmg $dmg"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-background-ready/1 -o "$out/head.dmg" "$dmg" || { echo "BR download failed"; return 3; }
}

# br_arm OUT ARM RUNS SETTLE IDLE SETTING: one arm on its own copy, home, config file and defaults, driven by one
# background-ready process in the console session; then every process of the copy stopped by pid, the defaults
# saved and checked against the arm's home.
br_arm() {
  local out="$1" arm="$2" runs="$3" settle="$4" idle="$5" setting="$6" app config cross status
  app="$(find "$out/$arm" -maxdepth 1 -name '*.app' | head -1)"
  mkdir -p "$out/home-$arm/h/.config/cmux" && chmod -R 0777 "$out/home-$arm"
  config="$out/home-$arm/h/.config/cmux/cmux-next.json"
  if [[ -n "$setting" ]]; then printf '{\n  "app": {\n    "backgroundReady": "%s"\n  }\n}\n' "$setting" >"$config"; else printf '{}\n' >"$config"; fi
  chmod 0666 "$config"
  echo "BR config $arm $(tr -d ' \n' <"$config")"
  defaults_aside "$out" "$app" || { echo "BR-FAIL $arm defaults not set aside"; return 1; }
  quiesce "$app" "$arm" prime | sed 's/^LR-SETTLE /BR-SETTLE /'
  side_defaults "$out" load "$app" "$out/home-$arm/defaults.plist" || { echo "BR-FAIL $arm defaults not loaded"; return 1; }
  BR_STARTED="$BR_STARTED $app"
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$out/background-ready" "$arm" "$app" "$out/home-$arm" \
    "$runs" "$settle" "$BR_SOCKETS/$arm.sock" "$idle" "$out/idle.py" "$config" 2>>"$out/driver-$arm.log" | tee -a "$out/lines.log" \
    | grep --line-buffered -E '^BR-(RUN|IDLE|FAIL|PID) '
  status=${PIPESTATUS[0]}
  br_stop "$out" "$app"
  BR_STARTED="${BR_STARTED% "$app"}"
  if side_defaults "$out" save "$app" "$out/home-$arm/defaults.plist"; then
    cross="$(python3 -I "$out/defaults.py" check "$out/home-$arm/defaults.plist" "$out/home-$arm/")"
  else
    cross='{"defaults_not_saved": true}'
  fi
  # runs.jsonl: every BR-RUN row with its arm (and the cross-arm read, when there was one).
  sed -n "s/^BR-RUN $arm //p" "$out/lines.log" | python3 -I -c 'import json,sys
for line in sys.stdin:
    r = json.loads(line); r["arm"] = sys.argv[1]; r["harness"] = "background-ready"
    r.update({"cross_arm": json.loads(sys.argv[2])} if sys.argv[2] else {})
    print(json.dumps(r, sort_keys=True))' "$arm" "$cross" >>"$out/runs.jsonl"
  sed -n "s/^BR-IDLE $arm //p" "$out/lines.log" >>"$out/idle.jsonl"
  [[ -z "$cross" ]] || { echo "BR-CROSS-ARM $arm $cross"; echo "BR-FAIL $arm read another arm's launch snapshot"; return 1; }
  [[ "$status" == 0 ]]
}

# br_stop OUT APP: every process of APP's copy ended by its pid (background-ready-idle.py stop), as the console user.
br_stop() {
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$1/idle.py" stop "$2" 2>>"$1/stop.log"
}

# At exit (a failed or killed step too): the copies of arms that did not end their own.
br_stop_all() {
  local app
  for app in $BR_STARTED; do br_stop "$1" "$app" >/dev/null; done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then br_main "$@"; exit $?; fi
