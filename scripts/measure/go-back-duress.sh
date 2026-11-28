#!/usr/bin/env bash
# Go back to the previous build under duress (#41013): the update harness (scripts/cmux-next/update-harness/run.py
# --sessions --rollback) updates a bench app to a newer copy of itself, then goes back through updates.rollback, with
# live agent turns and running terminals, on a quiet Mac and on a Mac loaded with busy loops. Rounds interleave:
# quiet 1, loaded 1, quiet 2, ...
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/go-back-duress.sh --ref <sha with this file> \
#     [--arg=rounds=3] [--arg=stress=12] [--arg=agents=4] [--arg=terminals=4] \
#     --artifact .build/go-back-duress/report.tgz --timeout 7200
#   rounds=N   1 to 5 (default 3)    stress=K  busy loops per core in the loaded rounds (default 12)
#   agents=N   active agent turns (default 4)    terminals=N  running counters (default 4)
# Prints GBD <mode> <round> {...} per go-back and GBD-MEDIAN <mode> {...}, in ms from the click (revert.clicked):
# click_to_window (the kept build's first window), click_to_old_exit, and whether sessions came back.
set -uo pipefail

main() {
  cd "$(dirname "$0")/../.." || exit 3
  source scripts/measure/build-progress.sh
  local out="$PWD/.build/go-back-duress" rounds=3 stress=12 agents=4 terminals=4 arg rc=0 i mode
  for arg in "$@"; do
    case "$arg" in
      rounds=*) rounds="${arg#rounds=}" ;;
      stress=*) stress="${arg#stress=}" ;;
      agents=*) agents="${arg#agents=}" ;;
      terminals=*) terminals="${arg#terminals=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$rounds" =~ ^[1-5]$ ]] || { echo "rounds= must be 1 to 5" >&2; exit 2; }
  [[ "$stress" =~ ^[0-9]{1,2}$ ]] || { echo "stress= takes busy loops per core, 0 to 99" >&2; exit 2; }
  [[ "$agents" =~ ^[1-9]$ && "$terminals" =~ ^[1-9]$ ]] || { echo "agents= and terminals= take 1 to 9" >&2; exit 2; }
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  echo "GBD host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) commit $(git rev-parse HEAD)"
  build_app "$out" || exit 3
  for ((i = 1; i <= rounds; i++)); do
    for mode in quiet loaded; do
      echo "GBD-ROUND $i $mode"
      [[ "$mode" == loaded ]] && start_stress "$stress"
      GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I scripts/cmux-next/update-harness/run.py \
        --app "$out/app/cmux DEV gbd.app" --tag gbd --out "$out/run-$mode-$i" --sessions \
        --agent-count "$agents" --terminal-count "$terminals" --rollback \
        2>&1 | tee -a "$out/run.log" | sed "s/^/[$mode $i] /"
      [[ ${PIPESTATUS[0]} == 0 ]] || rc=1
      stop_stress
    done
  done
  python3 -I - "$out" <<'PY'
import glob, json, os, statistics, sys
out = sys.argv[1]
rows = {}
for path in sorted(glob.glob(os.path.join(out, "run-*", "timeline.json"))):
    mode, rnd = os.path.basename(os.path.dirname(path)).split("-")[1:]
    try:
        hop = json.load(open(path)).get("rollback") or {}
    except (OSError, ValueError) as error:
        hop = {"error": str(error)}
    row = {"click_to_window": hop.get("click_to_window_ms"), "click_to_old_exit": hop.get("click_to_old_exit_ms"),
           "restored": {k: v for k, v in (hop.get("click_to_new") or {}).items() if k.startswith("launch.")},
           "refused": hop.get("refused"), "problem": hop.get("exit") or hop.get("window") or hop.get("error")}
    print("GBD", mode, rnd, json.dumps(row))
    rows.setdefault(mode, []).append(row)
for mode, rs in rows.items():
    med = {}
    for key in ("click_to_window", "click_to_old_exit"):
        vals = [r[key] for r in rs if isinstance(r[key], (int, float))]
        med[key] = round(statistics.median(vals)) if vals else None
        med[key + "_runs"] = vals
    print("GBD-MEDIAN", mode, json.dumps(med))
PY
  rm -rf "$out/app"
  tar -czf "$out.tgz" -C "$out" . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

# K busy loops per core for the whole loaded run, each ended by its own recorded pid.
STRESS_PIDS=()
start_stress() {
  local per_core="$1" cores n
  STRESS_PIDS=()
  [[ "$per_core" -gt 0 ]] || return 0
  cores="$(sysctl -n hw.ncpu)"
  for ((n = 0; n < per_core * cores; n++)); do
    yes >/dev/null &
    STRESS_PIDS+=("$!")
  done
  echo "GBD stress $((per_core * cores)) busy loops on $cores cores"
}
stop_stress() {
  local pid
  for pid in ${STRESS_PIDS[@]+"${STRESS_PIDS[@]}"}; do kill "$pid" 2>/dev/null; done
  for pid in ${STRESS_PIDS[@]+"${STRESS_PIDS[@]}"}; do wait "$pid" 2>/dev/null; done
  STRESS_PIDS=()
}
trap stop_stress EXIT

# Builds the checkout's bench app with tag gbd and copies it to OUT/app/.
build_app() {
  local out="$1" app started=$SECONDS
  for sub in ghostty ghostty-next; do
    git submodule update --init --depth 1 "$sub" >>"$out/build.log" 2>&1 || { echo "GBD submodule $sub failed" >&2; return 3; }
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh >>"$out/build.log" 2>&1 || { echo "GBD GhosttyKit download failed" >&2; return 3; }
  fi
  measure_quiet "GBD acpmux build" "$out/build.log" env CMUX_FLEET_BUILD_TAG=gbd ./scripts/cmux-next/build-acpmux.sh || { echo "GBD acpmux build failed" >&2; tail -n 40 "$out/build.log" >&2; return 3; }
  measure_quiet "GBD build" "$out/build.log" env CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag gbd --no-global-cli-links --config bench
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/build.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "GBD build failed: no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/build.log" | head -n 60 >&2
    tail -n 40 "$out/build.log" >&2
    return 3
  fi
  mkdir -p "$out/app" && ditto "$app" "$out/app/cmux DEV gbd.app" || { echo "GBD copy failed" >&2; return 3; }
  echo "GBD build $(git rev-parse HEAD) $((SECONDS - started)) s $(du -sh "$app" | cut -f1)"
}

main "$@"
