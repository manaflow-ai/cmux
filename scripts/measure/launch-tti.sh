#!/usr/bin/env bash
# Launch to first interaction (startup-tti) of a cmux NEXT build on a fleet Mac with a console session: the nightly
# launch-tti leg (cmuxterm-hq next-dogfood.yml) run on demand, so a number comes now and not at the next nightly.
# scripts/ci/launch_tti_check.py does the driving: 120 workspaces, cold and warm relaunches, process start to the
# front's first paint and to a typed key taken (terminal, Chromium browser tab, agent chat).
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/launch-tti.sh --ref <landed sha> [--arg=dmg=nightly|URL|build] [--arg=build=SHA] \
#     [--arg=config=bench|Release|Debug] [--arg=input=auto|posted|in_app] [--arg=plan=warm:terminal,warm:browser,warm:chat] \
#     [--arg=repeat=N] [--arg=load=none|busy|X] [--arg=min_quiet=N] [--arg=chats=6] [--arg=workspaces=120] \
#     [--arg=launch=open|exec] [--arg=control=500] [--arg=session=auto|own] \
#     --artifact .build/launch-tti/report.tgz --timeout 2400
#   plan=        KIND:FRONT rounds; repeat=N runs each item N times in a row (plan=cold_install:terminal repeat=20: the
#                startup-matrix row, twenty cold launches, printed as TTI-PCT p50/p95 with the load each ran at; the
#                controller's arg allowlist refuses a `*` in plan=, so the count goes in repeat=)
#   load=X       the load bound per core (default 0.5): each round waits up to 120 s for the 1-minute load per core to
#                fall to X; rounds launched over it are left out of TTI-PCT, and a cell under min_quiet=N (default 5)
#                quiet rounds is refused, never posted
#   dmg=nightly  the newest build the NIGHTLY feed offers (default); dmg=https://... one DMG
#   dmg=build    a tagged app built from this checkout (scripts/reload.sh, config=bench by default: Release
#                optimization with the debug.* commands; config=Release or config=Debug)
#   build=SHA    with dmg=build: build the tagged app at SHA (40 hex, a pull request's head, fetched when absent) with
#                that commit's own reload.sh (scripts/measure/app-at-commit.sh), while the check stays this checkout's
#                (the controller runs this script only at a landed commit; relaunch-restore.sh does the same)
#   input=       who types (the check's --input): auto posts keys when this process holds the PostEvent grant and
#                otherwise has the app type its own first-frame key (CMUX_NEXT_LAUNCH_TYPE_PROBE=1)
#   load=busy    one `yes > /dev/null` per core through each measured launch (the check stops them, on any exit too)
#   chats=N      chats in the session list (the l5 one and N - 1 more)
#   launch=      open (default): LaunchServices, activated, as a Dock click; exec: the harness execs the app
# Prints TTI-HOST (the Mac, its load), TTI-ROUND per round, RESTART-FIRST-PAINT per front and kind,
# RESTART-FIRST-PAINT-RATIO per kind and one TTI {json}; keeps tti.json and run.log in report.tgz.
#   control=MS   the bench's positive control: the plan runs twice on the same build, as is (base/) and with
#                CMUX_NEXT_LAUNCH_TEST_DELAY_MS=MS (delayed/: the app waits MS before any window, LaunchTestDelay;
#                1-5000), then launch_tti_control.py prints CONTROL delta_ms=X expected=MS pass|fail per metric
#                (first_frame per kind, first_chat_paint, launch_to_interaction per front) and the run fails unless
#                every delta is within 30% of MS. A build older than the knob shows no delta and fails.
#   session=     whose GUI session runs the app (console-session.sh's CONSOLE_SESSION): auto hops into the console
#                user's session with sudo; own runs in the invoking user's own GUI login with no sudo (a person's Mac
#                whose console is an agent screen account, e.g. air-blue)
# A non-zero exit ends with one TTI-FAIL line: the exit code and the reason (a CONSOLE-SESSION-FAIL, sudo refusal,
# traceback or the log's last line), so a bare "exit 1" never comes back.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/launch-tti"
rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
dmg=nightly config=bench build_sha="" extra=() control= plan= repeat=
for arg in "$@"; do
  case "$arg" in
    dmg=nightly|dmg=build|dmg=https://*) dmg="${arg#dmg=}" ;;
    build=*) build_sha="${arg#build=}" ;;
    config=bench|config=Release|config=Debug) config="${arg#config=}" ;;
    input=auto|input=posted|input=in_app) extra+=(--input "${arg#input=}") ;;
    load=none|load=busy) extra+=(--load "${arg#load=}") ;;
    load=*) extra+=(--max-load-per-core "${arg#load=}") ;;
    min_quiet=*) extra+=(--min-quiet "${arg#min_quiet=}") ;;
    launch=open|launch=exec) extra+=(--launch "${arg#launch=}") ;;
    plan=*) plan="${arg#plan=}" ;;
    repeat=*) repeat="${arg#repeat=}"
      [[ "$repeat" =~ ^[1-9][0-9]?$ ]] || { echo "repeat=N takes 1-99" >&2; exit 2; } ;;
    workspaces=*) extra+=(--workspaces "${arg#workspaces=}") ;;
    chats=*) extra+=(--chats "${arg#chats=}") ;;
    session=auto|session=own) export CONSOLE_SESSION="${arg#session=}" ;;
    control=*) control="${arg#control=}"
      [[ "$control" =~ ^[1-9][0-9]{0,3}$ ]] && (( control <= 5000 )) || { echo "control=MS takes 1-5000 ms" >&2; exit 2; } ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ -n "$repeat" ]]; then
  [[ -n "$plan" ]] || { echo "repeat=N needs plan=" >&2; exit 2; }
  plan="$(sed "s/\([^,]*\)/\1*$repeat/g" <<<"$plan")"  # each item N times: the check's KIND:FRONT*N
fi
[[ -n "$plan" ]] && extra+=(--plan "$plan")
if [[ -n "$build_sha" ]]; then
  [[ "$build_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "build=$build_sha: want a full 40-hex commit sha" >&2; exit 2; }
  [[ "$dmg" == build ]] || { echo "build=SHA needs dmg=build (it builds the app at SHA)" >&2; exit 2; }
fi
configuration=()
case "$config" in
  bench) configuration=(--config bench) ;;
  Release) configuration=(--release) ;;
esac
source_args=()
if [[ -n "$build_sha" ]]; then
  echo "TTI build $build_sha config $config"
  echo "TTI driver $(git rev-parse HEAD)"
  . scripts/measure/app-at-commit.sh
  # The commit's worktree lives outside $out, so report.tgz holds its build log and not its tree.
  at_dir="$(mktemp -d)"
  trap 'rm -rf -- "$at_dir"' EXIT
  app="$(measure_app_at_commit "$build_sha" ttilaunch "$at_dir/at" --no-global-cli-links ${configuration[@]+"${configuration[@]}"} 2>"$out/reload.log")"
  if [[ $? -ne 0 || -z "$app" || ! -d "$app" ]]; then
    echo "TTI build failed: the build at $build_sha printed no app path" >&2
    tail -n 60 "$out/reload.log" >&2
    exit 3
  fi
  trap 'python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1; rm -rf -- "$at_dir"' EXIT
  source_args=(--app "$app")
elif [[ "$dmg" == build ]]; then
  echo "TTI build $(git rev-parse HEAD) config $config"
  # A fleet step checks out no submodules: the app build needs Ghostty's headers and the ghostty-next tree,
  # and GhosttyKit.xcframework (a prebuilt download), as perf-idle-power.sh fetches them.
  for sub in ghostty ghostty-next; do
    [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" || exit 3
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh || exit 3
  fi
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag ttilaunch --no-global-cli-links ${configuration[@]+"${configuration[@]}"} >"$out/reload.log" 2>&1
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "TTI build failed: the tagged build printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2
    tail -n 40 "$out/reload.log" >&2
    exit 3
  fi
  # The tagged app's processes end with the step, also when the check is stopped mid-run.
  trap 'python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1' EXIT
  source_args=(--app "$app")
else
  if [[ "$dmg" == nightly ]]; then
    feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-tti/1 -H "Cache-Control: no-cache" -o "$out/feed.xml" "$feed" || { echo "TTI feed download failed"; exit 3; }
    picked="$(python3 scripts/ci/nightly_next_launch_smoke.py pick --feed "$out/feed.xml")" || { echo "TTI no nightly build on the feed"; exit 3; }
    echo "$picked" | sed 's/^/TTI pick /'
    dmg="$(sed -n 's/^url=//p' <<<"$picked")"
  fi
  echo "TTI dmg $dmg"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-tti/1 -o "$out/in.dmg" "$dmg" || { echo "TTI download failed"; exit 3; }
  source_args=(--dmg "$out/in.dmg")
fi
python3 -I -c 'import json, os, shutil, socket; print("TTI-HOST " + json.dumps({"name": socket.gethostname().split(".")[0], "cpus": os.cpu_count(), "load_at_launch": round(os.getloadavg()[0], 2), "free_disk_gb": round(shutil.disk_usage(os.path.expanduser("~")).free / 1e9, 1)}))' | tee "$out/run.log"
tti() {  # tti OUT [ARGS...]: one run of the check's plan into OUT
  local dir="$1"; shift
  mkdir -p "$dir" && chmod 0777 "$dir"
  scripts/ci/frame-pacing/console-session.sh python3 -I "$PWD/scripts/ci/launch_tti_check.py" ${source_args[@]+"${source_args[@]}"} --out "$dir" \
    ${extra[@]+"${extra[@]}"} "$@" 2>&1 | tee -a "$out/run.log"
  return "${PIPESTATUS[0]}"
}
if [[ -z "$control" ]]; then
  tti "$out"; rc=$?
else
  echo "TTI control: base run, then delayed by ${control} ms" | tee -a "$out/run.log"
  tti "$out/base"; base_rc=$?
  tti "$out/delayed" --launch-delay-ms "$control"; delayed_rc=$?
  python3 -I scripts/ci/launch_tti_control.py --base "$out/base/tti.json" --delayed "$out/delayed/tti.json" \
    --expected "$control" 2>&1 | tee -a "$out/run.log"
  control_rc=${PIPESTATUS[0]}
  rc=$control_rc
  (( base_rc != 0 )) && rc=$base_rc
  (( delayed_rc != 0 )) && rc=$delayed_rc
fi
if [ "$rc" -ne 0 ]; then
  reason="$(grep -E 'CONSOLE-SESSION-FAIL|sudo: |LR-FAIL|Traceback|Error|error:' "$out/run.log" | head -3 | tr '\n' ' ')"
  [ -n "$reason" ] || reason="$(grep -v '^TTI-HOST ' "$out/run.log" | tail -1)"
  echo "TTI-FAIL rc=$rc reason=${reason:-no output from launch_tti_check.py}" | tee -a "$out/run.log"
fi
rm -f "$out/in.dmg"
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz --exclude tti-marks.fifo . 2>/dev/null || true
exit "$rc"
