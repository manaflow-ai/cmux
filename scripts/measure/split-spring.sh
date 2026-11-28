#!/usr/bin/env bash
# Fleet entry for the rapid Cmd-D / Cmd-Shift-D run (split-spring): builds a tagged cmux-next app at this
# checkout, then runs scripts/cmux-next/split-spring-terminal.py against it (five splits 100 ms apart
# from one terminal with scrollback, optionally streaming; missed frames, frame intervals, layout work,
# grids sent to the PTY owner, hangs). Needs a logged-in console (an owned mini).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \
#     --ref <sha> --artifact artifacts/split-spring/report.json [--arg=--rounds=3] [--arg=--stream] [--arg=--gate]
# To time an older commit, revert the change on a scratch ref of the tip (the script blob must match the reviewed one).
#
# Options this script reads (the rest go to split-spring-terminal.py):
#   --app-cache     (the default) reuse this commit's app when an earlier step on this worker built it
#                   ($CI_SHARED_CACHE_DIR/split-spring-apps/<sha>), and keep it there after a build (the 3
#                   newest unpinned commits) while the volume keeps SPLIT_SPRING_CACHE_MIN_FREE_GIB (60) free.
#                   The perf cron (scripts/cmux-next/perf-cron.py) builds once per measurement. It was opt-in until
#                   2026-11-27: 150 of 184 split-spring steps in 24 h passed no --app-cache, 9 of 58 started ones
#                   re-ran a ref their worker had already built, and the build was 49% of split-spring's 30.9
#                   held-Mac hours (measure-queue-wait, controller /v1/jobs/history).
#   --no-app-cache  build fresh and keep nothing (a measurement of the build itself, or a suspect cache).
#   --build-only    build (or find) the app, keep it in the cache and pin it there for 13 h (`pin`; a perf cron
#                   measurement is abandoned after 12 h), measure nothing; report.json records the build. No
#                   eviction removes a pinned app, so a measurement's later parts never build cold.
#   --vdisplay=HZ   measure on a virtual display at HZ (scripts/ci/frame-pacing/vdisplay.m, the private
#                   CGVirtualDisplay API), which the helper makes the main display (`main`: origin 0,0, for
#                   this process only) so the app opens on it. When it does not come up as the main display at
#                   that rate, the step measures on the real display and says so (VDISPLAY-FALLBACK). The
#                   report (report.json, perf-gate.json) gets a `display` key either way: {requested_hz,
#                   vdisplay, refresh_ms, line}. refresh_ms is the virtual display's measured interval, or after a
#                   fallback the real main display's (`VDisplay probe`; null only when that does not tick either).
#                   Not yet confirmed on cmux20-bench by a perf cron run (2026-10-23).
#   --config=bench  build the app in the bench configuration (reload.sh --config bench: Release optimization with
#                   the debug.* control commands kept), so the bench measures an optimized app; cached apart.
#   --vdisplay-hold=SECONDS  the helper's own lifetime (default 1200): it ends by itself even when this script
#                   is killed with SIGKILL. The perf cron passes the part's run time.
#   --vdisplay-size=WxH  the virtual display's pixels (default 1920x1200: under the Dock a 1920x1080 display left
#                   about 965 pt, and AppKit clamped the 1600 x 1000 STRESS window, 2026-10-24). The helper's ready
#                   line reports the visible frame (visible=WxH), which the report's display.line keeps.
#   --cpu-load      measure under full CPU load: before the bench starts, 4-thread spinners
#                   (scripts/measure/qos-load-bench/spin.c) at the default priority, more threads than the host has
#                   cores (hw.ncpu / 4 + 1 spinners), the same load as qos-load-bench.sh. They are stopped by PID when
#                   the bench ends. The report gets `cpu_load`: {spinners, threads, ncpu}, or null without the option.
#                   The perf cron never passes it; it is for a before/after pair under load ("idle and under load").
# On exit, TERM, INT or HUP (a cancelled step) the script stops the bench, ends the tag's app and daemons
# (scripts/cmux-next/tag_teardown.py, exact PIDs of the app bundle) and the virtual display.
set -euo pipefail
# The measurement's version (scripts/cmux-next/perf-cron.py MEASURE_VERSION_RE): the perf cron measures and compares only
# commits whose version is the tip's. Bump it in an edit that changes what is measured or how (the build, the display,
# the suites, the args); a comment, log or report-key edit keeps it, so it keeps the history measurable.
SPLIT_SPRING_MEASURE_VERSION=5  # 5: workspace-scaling adds a dispatcher suite (historical commits without it must not be bisected as another suite); 4: STRESS sessions open their extra terminal, Chromium and WebKit tabs (add_tab had a pane target the actions refuse; 3: the virtual display is 1920x1200)
cd "$(git rev-parse --show-toplevel)"
cpu_load=0 build_only=0 app_cache=1 vdisplay_hz="" vdisplay_hold=1200 vdisplay_size=1920x1200 args=() reload_config=()
for arg in "$@"; do
  case "$arg" in
    --build-only) build_only=1 app_cache=1 ;;
    --app-cache) app_cache=1 ;;
    --no-app-cache) app_cache=0 ;;
    --cpu-load) cpu_load=1 ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    --vdisplay-hold=*) vdisplay_hold="${arg#--vdisplay-hold=}" ;;
    --vdisplay-size=*) vdisplay_size="${arg#--vdisplay-size=}" ;;
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) args+=("$arg") ;;
  esac
done
tag="split-spring"
out="$(pwd)/artifacts/split-spring"
mkdir -p "$out"
sha="$(git rev-parse HEAD)"
# Keyed by the app's sources, not the commit: the bench's own scripts (scripts/cmux-next, scripts/measure) build
# nothing, so a change to them alone reuses the app. Every other path, the build scripts in scripts/ too, is in the key.
key="$( { git ls-tree HEAD | grep -v $'\tscripts$'; git ls-tree HEAD:scripts | grep -v -E $'\t(cmux-next|measure)$'; } \
  | git hash-object --stdin)"
# A bench build (--config=bench) is cached apart from the default Debug build of the same sources.
[[ ${#reload_config[@]} -gt 0 && "${reload_config[1]}" != debug ]] && key="$key-${reload_config[1]}"
cache=""
if [[ "$app_cache" == 1 && -n "${CI_SHARED_CACHE_DIR:-}" ]]; then
  cache="$CI_SHARED_CACHE_DIR/split-spring-apps"
fi
# >>> follow-log (scripts/measure/tests/split-spring-follow-log.test.sh runs these two)
# follow_log FILE: prints FILE's lines as they come, each prefixed "reload-log: ", from a `tail` this script starts
# (its PID in follow_pid). FILE starts empty, so only this run's lines show.
follow_log() {
  : > "$1" 2>/dev/null || true
  tail -n +1 -F "$1" 2>/dev/null > >(awk '{ print "reload-log: " $0; fflush() }') &
  follow_pid=$!
}
# unfollow_log: ends the `tail` follow_log started, by its own PID; its awk ends with it.
unfollow_log() {
  if [[ -n "${follow_pid:-}" ]]; then
    kill "$follow_pid" 2>/dev/null || true
    wait "$follow_pid" 2>/dev/null || true
  fi
  follow_pid=""
}
# The controller stops a measurement that prints nothing for CMUX_CI_MEASURE_SILENT_MAX (45 min) as a
# hung one. xcodebuild prints nothing while it compiles, so a slow build and a wedged build look the
# same from outside, and two steps at one ref were killed mid-build on two hosts (cmux20-bench step
# 3844a9ea8e9d6bafaf6e9ff2, cmux23 step 8dcc5985a8b0aedb25014cf9) while `compile-check --app` at that
# same ref passed in 148 s. A heartbeat says the build is alive.
#
# Bounded on purpose: after BUILD_HEARTBEAT_MAX it stops, so a build that really is wedged still goes
# silent and the controller still frees the host. The heartbeat buys a slow build its time; it does
# not turn the hang detector off.
BUILD_HEARTBEAT_EVERY=${BUILD_HEARTBEAT_EVERY:-120}
BUILD_HEARTBEAT_MAX=${BUILD_HEARTBEAT_MAX:-5400}
# heartbeat_start: prints one line every BUILD_HEARTBEAT_EVERY seconds while the build runs.
heartbeat_start() {
  (
    started=$SECONDS
    while :; do
      sleep "$BUILD_HEARTBEAT_EVERY"
      elapsed=$((SECONDS - started))
      if (( elapsed > BUILD_HEARTBEAT_MAX )); then
        echo "split-spring: building, ${elapsed} s elapsed: past ${BUILD_HEARTBEAT_MAX} s, no more heartbeats (a build this long is a hang; the controller's silent limit takes it from here)"
        break
      fi
      echo "split-spring: building, ${elapsed} s elapsed"
    done
  ) &
  heartbeat_pid=$!
}
# heartbeat_stop: ends the heartbeat by its own PID.
heartbeat_stop() {
  if [[ -n "${heartbeat_pid:-}" ]]; then
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
  fi
  heartbeat_pid=""
}
# <<< follow-log
# The heartbeat runs from here until the app is ready, and each step says its name first: a glass-perf step
# on cmux-austin-mini-0 (1dc02f92) printed nothing after the worker's checkout, before reload.sh started,
# and the controller stopped it after 45 min with no step named. The heartbeat used to start only with
# reload.sh, so the app-cache copy, the submodule fetch and the GhosttyKit download ran silent.
heartbeat_start
trap 'heartbeat_stop' EXIT
build_start=$SECONDS
app="" cached=false
if [[ -n "$cache" && -f "$cache/$key/ok" ]]; then
  echo "split-spring: copying the cached app (key $key)"
  mkdir -p "$out/app"
  ditto "$cache/$key/cmux DEV $tag.app" "$out/app/cmux DEV $tag.app"
  touch "$cache/$key/ok"
  app="$out/app/cmux DEV $tag.app" cached=true
  echo "split-spring: the app of $sha from the app cache ($((SECONDS - build_start)) s)"
fi
if [[ -z "$app" ]]; then
  for sub in ghostty ghostty-next; do
    if [ ! -e "$sub/.git" ]; then
      echo "split-spring: fetching submodule $sub"
      git submodule update --init --depth 1 "$sub"
    fi
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    echo "split-spring: getting GhosttyKit"
    ./scripts/download-prebuilt-ghosttykit.sh
  fi
  # Streamed, not `| tail -n 40`: the tail held back reload.sh's pre-build lines (the pin-cmux-tui.sh wait, the
  # cargo and web-bundle builds) until it exited, which read as a hang (cmux20-bench step 0b17cb3f). The
  # xcodebuild compile itself still prints nothing until reload.sh exits (it keeps that in its own log).
  # reload.sh keeps its own log in /tmp/cmux-reload-<tag>.log and prints nothing while xcodebuild runs: follow that
  # log into this step's output, so a hang or a long build names its step (FC-1: cmux-austin-mini-1 step 9e972777
  # stopped after 45 min with no output after "reload starting").
  # Only an EXIT trap while reload.sh runs: bash runs a TERM/INT/HUP trap only after the foreground pipeline ends (a
  # hung reload never does), while an EXIT trap alone runs at once when such a signal ends the script.
  echo "split-spring: building the app (reload.sh --tag $tag)"
  follow_log "/tmp/cmux-reload-$tag.log"
  trap 'unfollow_log; heartbeat_stop' EXIT
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
  unfollow_log
  trap 'heartbeat_stop' EXIT
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "split-spring: the tagged reload printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
    # reload.sh keeps xcodebuild's output in its own log (`==> log: PATH`): the compiler's errors are there.
    build_log="$(sed -n 's/^==> log: //p' "$out/reload.log" | tail -n 1)"
    if [[ -n "$build_log" && -f "$build_log" ]]; then
      grep -E "\.swift:[0-9]+:[0-9]+: error|error: |Stack dump|signal" "$build_log" | head -n 40 >&2 || true
    fi
    exit 1
  fi
  # A kept app is a few GiB: on a short volume (the 256 GB minis sit near the measure floor) keep nothing and
  # leave the space to the next step's build.
  free_gib="$(df -Pk "${CI_SHARED_CACHE_DIR:-.}" 2>/dev/null | awk 'NR==2 { print int($4 / 1048576) }')"
  if [[ -n "$cache" && "$build_only" != 1 && "${free_gib:-0}" -lt "${SPLIT_SPRING_CACHE_MIN_FREE_GIB:-60}" ]]; then
    echo "split-spring: not keeping the app (${free_gib:-?} GiB free < ${SPLIT_SPRING_CACHE_MIN_FREE_GIB:-60} GiB)"
    cache=""
  fi
  if [[ -n "$cache" ]]; then
    mkdir -p "$cache"
    rm -rf "${cache:?}/$key.tmp"
    mkdir -p "$cache/$key.tmp"
    if ditto "$app" "$cache/$key.tmp/cmux DEV $tag.app"; then
      rm -rf "${cache:?}/$key"
      mv "$cache/$key.tmp" "$cache/$key"
      touch "$cache/$key/ok"
      echo "split-spring: kept the app of $sha in the app cache"
    fi
  fi
fi
heartbeat_stop
trap - EXIT
if [[ -n "$cache" && -d "$cache/$key" ]]; then
  [[ "$build_only" == 1 ]] && touch "$cache/$key/pin"
  # Keep the 3 newest unpinned apps; a pin younger than 13 h (780 min) keeps its app whatever its age.
  # shellcheck disable=SC2012 # the directory names are 40-hex commit ids
  ls -1t "$cache"/*/ok 2>/dev/null | while read -r ok; do
    dir="$(dirname "$ok")"
    if [[ -f "$dir/pin" && -n "$(find "$dir/pin" -mmin -780 2>/dev/null)" ]]; then
      continue
    fi
    echo "$dir"
  done | tail -n +4 | while read -r old; do rm -rf "$old"; done
fi
build_seconds=$((SECONDS - build_start))
# The host's macOS version: every report carries it (the perf cron shows each host's macOS; rows of one host only
# are compared).
macos="$(sw_vers -productVersion 2>/dev/null | tr -cd '0-9.' | head -c 16 || true)"
if [[ "$build_only" == 1 ]]; then
  printf '{"build": {"sha": "%s", "seconds": %d, "cached": %s}, "macos": "%s"}\n' "$sha" "$build_seconds" "$cached" "$macos" > "$out/report.json"
  cat "$out/report.json"
  exit 0
fi

vdisplay_pid="" bench_pid="" measuring=0 spin_pids=()
# shellcheck disable=SC2329 # run by cleanup
stop_cpu_load() {
  local pid
  for pid in ${spin_pids[@]+"${spin_pids[@]}"}; do kill "$pid" 2>/dev/null || true; done  # the spinners this script started, by PID
  for pid in ${spin_pids[@]+"${spin_pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
  spin_pids=()
}
stop_vdisplay() {
  if [[ -n "$vdisplay_pid" ]]; then
    kill "$vdisplay_pid" 2>/dev/null || true  # the helper this script started, by its PID
    wait "$vdisplay_pid" 2>/dev/null || true  # its display arrangement is gone once it has exited
    vdisplay_pid=""
  fi
}
# shellcheck disable=SC2329 # run by the traps below
cleanup() {
  trap - EXIT TERM INT HUP
  unfollow_log
  if [[ -n "$bench_pid" ]] && kill -0 "$bench_pid" 2>/dev/null; then
    kill -TERM "$bench_pid" 2>/dev/null || true  # the bench this script started, by its PID
    wait "$bench_pid" 2>/dev/null || true
  fi
  stop_cpu_load
  if [[ "$measuring" == 1 ]]; then
    python3 scripts/cmux-next/tag_teardown.py "$app" || true
  fi
  stop_vdisplay
}
# shellcheck disable=SC2329 # run by the traps below
on_signal() {
  echo "split-spring: signal $1; ending the bench, the app and the virtual display" >&2
  cleanup
  exit $((128 + $2))
}
trap cleanup EXIT
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2' INT
trap 'on_signal HUP 1' HUP
display_json='null'
if [[ -n "$vdisplay_hz" ]]; then
  vd="$out/vdisplay"
  mkdir -p "$vd/VDisplay.app/Contents/MacOS"
  line="error: the virtual display helper did not compile"
  if xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
      scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay" 2> "$vd/clang.err"; then
    cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
    codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
    "$vd/VDisplay.app/Contents/MacOS/VDisplay" "$vdisplay_hz" "$vdisplay_hold" main "$vdisplay_size" > "$vd/out" 2> "$vd/err" &
    vdisplay_pid=$!
    for _ in $(seq 20); do
      grep -q '^ready\|^error' "$vd/out" 2>/dev/null && break
      kill -0 "$vdisplay_pid" 2>/dev/null || break
      sleep 1  # bounded wait for the helper's own ready line
    done
    line="$(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo "error: the virtual display never reported ($(head -c 300 "$vd/err" 2>/dev/null || true))")"
  fi
  # `ready DISPLAY_ID P50_MS main=MAIN_ID`: the main display, ticking within 15 % of the rate. Prints the
  # report's `display` value.
  if display_json="$(python3 - "$line" "$vdisplay_hz" true <<'PY'
import json, re, sys
m = re.match(r"ready (\d+) ([\d.]+) main=(\d+)", sys.argv[1])
period = 1000 / float(sys.argv[2])
ok = bool(m and m.group(1) == m.group(3) and abs(float(m.group(2)) - period) <= 0.15 * period)
print(json.dumps({"requested_hz": float(sys.argv[2]), "vdisplay": ok, "refresh_ms": float(m.group(2)) if ok else None,
                  "line": sys.argv[1][:300]}))
sys.exit(0 if ok else 1)
PY
)"; then
    echo "split-spring: VDISPLAY ${vdisplay_hz} Hz main display ($line)"
    # Until a new process sees the virtual display as its main display (what the app opens on), 15 s.
    # Only when the helper's ready line says it made the display main (main=ID).
    vd_id="$(sed -n 's/^ready \([0-9]*\) [0-9.]* main=\1 .*/\1/p' "$vd/out" 2>/dev/null | head -1 || true)"
    if [[ -n "$vd_id" ]]; then
      vd_main="" vd_deadline=$((SECONDS + 15))
      while (( SECONDS < vd_deadline )); do
        vd_main="$("$vd/VDisplay.app/Contents/MacOS/VDisplay" probe 2>/dev/null | awk '$1 == "main" {print $2}' || true)"
        [[ "$vd_main" == "$vd_id" ]] && break
        sleep 0.2
      done
      [[ "$vd_main" == "$vd_id" ]] || echo "warning: a new process still sees display ${vd_main:-?} as main, not the virtual display $vd_id, after 15 s" >&2
    fi
  else
    echo "split-spring: VDISPLAY-FALLBACK no ${vdisplay_hz} Hz virtual display ($line); measuring on the real display"
    stop_vdisplay
    # The real main display's measured rate, so the frame rows of a fallback run still have a known refresh.
    probe=""
    if [[ -x "$vd/VDisplay.app/Contents/MacOS/VDisplay" ]]; then
      probe="$("$vd/VDisplay.app/Contents/MacOS/VDisplay" probe 2>/dev/null | grep -m1 '^main ' || true)"
    fi
    if probed="$(python3 - "$display_json" "$probe" <<'PY'
import json, re, sys
display = json.loads(sys.argv[1]) if sys.argv[1] else {}
m = re.match(r"main (\d+) ([\d.]+)", sys.argv[2])
ms = float(m.group(2)) if m else 0.0
display["refresh_ms"] = ms if 2 <= ms <= 50 else None
display["host_display"] = sys.argv[2][:200] or None
print(json.dumps(display))
PY
)"; then
      display_json="$probed"
    fi
    echo "split-spring: the real display: ${probe:-not measured}"
  fi
  echo "$line" > "$out/display.txt"
fi

cpu_load_json='null'
if [[ "$cpu_load" == 1 ]]; then
  ncpu="$(sysctl -n hw.ncpu)"
  spinners=$((ncpu / 4 + 1))
  cc -O2 -o "$out/spin" scripts/measure/qos-load-bench/spin.c
  for _ in $(seq "$spinners"); do "$out/spin" & spin_pids+=($!); done
  cpu_load_json="{\"spinners\": $spinners, \"threads\": $((spinners * 4)), \"ncpu\": $ncpu}"
  echo "split-spring: CPU-LOAD $spinners spinners, $((spinners * 4)) threads on $ncpu cores"
  # Until every spinner runs on its cores before the app launches: each has used at least 1 s of CPU (its
  # 4 threads, a quarter second of wall time), 10 s deadline.
  spun=0
  for _ in $(seq 100); do
    spun="$(ps -o time= -p "$(IFS=,; echo "${spin_pids[*]-}")" 2>/dev/null |
      awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; if (s >= 1) n++ } END { print n + 0 }' || true)"
    (( ${spun:-0} >= spinners )) && break
    sleep 0.1
  done
  (( ${spun:-0} >= spinners )) || echo "split-spring: CPU-LOAD only ${spun:-0} of $spinners spinners used 1 s of CPU within 10 s" >&2
fi

status=0
measuring=1
# In the background and waited for, so a TERM reaches the trap at once (bash runs a trap only between commands).
python3 scripts/cmux-next/split-spring-terminal.py --tag "$tag" --app "$app" --out "$out" --json "$out/report.json" \
  ${args[@]+"${args[@]}"} &
bench_pid=$!
wait "$bench_pid" || status=$?
bench_pid=""
stop_cpu_load
# Every report the step returns says which display it measured on (the perf cron reads `display.refresh_ms`) and the
# host's macOS version.
for report in "$out/report.json" "$out/perf-gate.json"; do
  [[ -f "$report" ]] || continue
  python3 - "$report" "$display_json" "$macos" "$cpu_load_json" <<'PY' || echo "split-spring: could not add the display to $report" >&2
import json, sys
path, display = sys.argv[1], json.loads(sys.argv[2])
with open(path) as f:
    report = json.load(f)
if isinstance(report, dict):
    report["display"] = display
    report["macos"] = sys.argv[3] or None
    report["cpu_load"] = json.loads(sys.argv[4])
    with open(path, "w") as f:
        json.dump(report, f, indent=1)
PY
done
exit "$status"
