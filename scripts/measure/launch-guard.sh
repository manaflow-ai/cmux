#!/usr/bin/env bash
# The #17587 launch guard and launch marks on a fleet GUI worker, for prebuilt fleet apps
# (cmux-ci build cmux jobs), light (bench-startup --profile realistic, 24 workspaces) and STRESS
# (scripts/cmux-next/perf-stress-session.py, primed by launch-guard-stress-prime.py). Runs alone on an
# idle worker with a console session of the worker account, because it launches apps:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/launch-guard.sh \
#     --ref SHA --arg=apps=JOB[,JOB...] [--arg=suite=light|stress|both] [--arg=runs=5] \
#     [--arg=light_modes=warm,kept] [--arg=stress_modes=warm,kept] [--arg=budget=150] \
#     --artifact artifacts/launch-guard.tar.gz
# Each app is the artifact of a finished `cmux-ci build cmux` job, fetched with the worker's cmux-ci.
# Every bench-startup run's exit code is printed (LAUNCH-GUARD-RESULT); the step exits 0 when every
# run produced its json, so a red guard on a base build is a result, not a step failure.
set -uo pipefail
apps="" suite=both runs=5 light_modes="warm,kept" stress_modes="warm,kept" budget=150
for arg in "$@"; do
  case "$arg" in
    apps=*) apps="${arg#apps=}" ;;
    suite=*) suite="${arg#suite=}" ;;
    runs=*) runs="${arg#runs=}" ;;
    light_modes=*) light_modes="${arg#light_modes=}" ;;
    stress_modes=*) stress_modes="${arg#stress_modes=}" ;;
    budget=*) budget="${arg#budget=}" ;;
    *) echo "launch-guard.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ -n "$apps" ]] || { echo "launch-guard.sh: give apps=JOB[,JOB...]" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)" || exit 2
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
out="$PWD/artifacts/launch-guard"
work="$PWD/.build/launch-guard"
rm -rf "$out" "$work"
mkdir -p "$out" "$work/apps"
console="$(stat -f%Su /dev/console)"
display="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|UI Looks like|Retina|Main Display' | sed 's/^ *//' | tr '\n' ';')"
echo "LAUNCH-GUARD-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) account=$(id -un) console=$console sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macos=$(sw_vers -productVersion) build=$(sw_vers -buildVersion) display=\"$display\" load=\"$(sysctl -n vm.loadavg)\""
if [[ "$console" != "$(id -un)" ]]; then
  echo "launch-guard.sh: the console user is $console, not $(id -un): no GUI session for the app" >&2
  exit 3
fi
cmux_ci="$account_home/.local/bin/cmux-ci"
[[ -x "$cmux_ci" ]] || { echo "launch-guard.sh: no cmux-ci at $cmux_ci" >&2; exit 3; }

staged=()
IFS=',' read -r -a jobs <<< "$apps"
for job in "${jobs[@]}"; do
  dir="$work/apps/$job"
  mkdir -p "$dir"
  "$cmux_ci" status "$job" > "$dir/job.json" 2>"$dir/status.err" || { cat "$dir/status.err" >&2; exit 3; }
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("APP-JOB job=%s tag=%s ref=%s state=%s artifact=%s" % (d["id"], d.get("tag"), d.get("ref"), d.get("state"), d.get("artifact")))' "$dir/job.json"
  "$cmux_ci" artifact "$job" "$dir/app.zip" > "$dir/artifact.log" 2>&1 || { tail -n 20 "$dir/artifact.log" >&2; exit 3; }
  ditto -x -k "$dir/app.zip" "$dir/x" || exit 3
  rm -f "$dir/app.zip"
  app="$(find "$dir/x" -maxdepth 3 -name 'cmux DEV *.app' -type d | head -n 1)"
  [[ -n "$app" ]] || { echo "launch-guard.sh: job $job has no cmux DEV app" >&2; exit 3; }
  echo "APP-STAGED job=$job app=\"$app\""
  staged+=("$app")
done

failed=0
modes_args() { local m; for m in ${1//,/ }; do printf -- '--mode\n%s\n' "$m"; done; }
record() {  # suite tag exit json
  echo "LAUNCH-GUARD-RESULT suite=$1 tag=$2 exit=$3 json=$([[ -s "$4" ]] && echo present || echo missing)"
  [[ -s "$4" ]] || failed=1
}

if [[ "$suite" == light || "$suite" == both ]]; then
  for app in "${staged[@]}"; do
    tag="$(basename "$app" .app)"; tag="${tag#cmux DEV }"
    echo "=== LIGHT $tag (realistic profile, ${REALISTIC:-24} workspaces)"
    mapfile_modes=()
    while IFS= read -r line; do mapfile_modes+=("$line"); done < <(modes_args "$light_modes")
    python3 scripts/cmux-next/bench-startup.py --app "$app" --profile realistic "${mapfile_modes[@]}" --runs "$runs" \
      --launch-guard --hangs 50 --budget "first_window_frame_committed=$budget" --json "$out/light-$tag.json" 2>&1 | tee "$out/light-$tag.log"
    record light "$tag" "${PIPESTATUS[0]}" "$out/light-$tag.json"
  done
fi

if [[ "$suite" == stress || "$suite" == both ]]; then
  for app in "${staged[@]}"; do
    tag="$(basename "$app" .app)"; tag="${tag#cmux DEV }"
    for mode in ${stress_modes//,/ }; do
      echo "=== STRESS $tag $mode"
      # warm: the prime quits keeping sessions (frames of every visible pane saved, daemon running);
      # kept: the prime ends sessions and keeps the layout, and kept mode's own priming launch does so again per run.
      quit=keep; [[ "$mode" == kept ]] && quit=end-sessions
      python3 scripts/measure/launch-guard-stress-prime.py --app "$app" --out "$out/stress-prime-$tag-$mode" --quit "$quit" 2>&1 \
        | tee "$out/stress-prime-$tag-$mode.log" | grep -E '^(STRESS-SESSION|STRESS-CEF|stress prime:|activation-perf:)'
      prime_exit="${PIPESTATUS[0]}"
      echo "STRESS-PRIME tag=$tag mode=$mode exit=$prime_exit"
      python3 scripts/cmux-next/bench-startup.py --app "$app" --mode "$mode" --runs "$runs" \
        --launch-guard --hangs 50 --budget "first_window_frame_committed=$budget" --json "$out/stress-$tag-$mode.json" 2>&1 | tee "$out/stress-$tag-$mode.log"
      record "stress-$mode" "$tag" "${PIPESTATUS[0]}" "$out/stress-$tag-$mode.json"
    done
  done
fi

python3 - "$out" <<'PY'
import glob, json, os, statistics, sys
out = sys.argv[1]
marks = ["first_window_frame_committed", "daemon.first_tree_applied", "first_terminal_frame", "sidebar_rows_shown",
         "terminal.launch_frame_shown"]
print("LAUNCH-GUARD-SUMMARY (median/max ms since process start; n = runs with the mark)")
for path in sorted(glob.glob(os.path.join(out, "*.json"))):
    suite = os.path.basename(path)[:-5]
    with open(path) as f:
        data = json.load(f)
    for tag, modes in data.items():
        for mode, runs in modes.items():
            cells = []
            for mark in marks:
                values = [run[mark] for run in runs if mark in run]
                cells.append(f"{mark}={statistics.median(values):.0f}/{max(values):.0f} n={len(values)}" if values else f"{mark}=missing")
            terminals = [run["terminals"] for run in runs if "terminals" in run]
            if terminals:
                cells.append("terminals(shown_live,hidden_live)=" + ",".join(f"({t['shown_live']},{t['hidden_live']})" for t in terminals))
            reads = sorted({name for run in runs for name in run if name.startswith("launch_read_on_main.")})
            cells.append("main_thread_reads=" + (",".join(reads) or "none"))
            stalls = [max([s["ms"] for s in run.get("stalls", [])] or [0]) for run in runs]
            cells.append("worst_stall_per_run=" + ",".join(f"{s:.0f}" for s in stalls))
            print(f"  {suite} {tag} {mode} ({len(runs)} runs): " + "; ".join(cells))
PY
tar -czf artifacts/launch-guard.tar.gz -C artifacts launch-guard
echo "launch-guard.sh: done (harness failures: $failed)"
exit "$failed"
