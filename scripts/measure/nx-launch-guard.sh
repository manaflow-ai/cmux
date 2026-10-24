#!/usr/bin/env bash
# The #17587 launch guard for one fleet app in an nx-remote GUI job (the controller's ci-step allowlist
# takes only reviewed scripts/measure blobs, so launch-guard.sh cannot run as a cmux-ci step):
#   nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA -- \
#     'git fetch -q origin HARNESS && git checkout -q HARNESS -- scripts && bash scripts/measure/nx-launch-guard.sh light,stress'
# light: bench-startup --profile realistic --mode warm --mode kept (24 workspaces); light-warm: warm only;
# stress: STRESS primed by launch-guard-stress-prime.py, then warm (keep quit) and kept (End Sessions quit).
# RUNS (default 5). Prints LAUNCH-GUARD-RESULT per run set and the LAUNCH-GUARD-SUMMARY of launch-guard.sh.
set -uo pipefail
suites="${1:-light,stress}"
runs="${RUNS:-5}"
app="${NX_APP:?NX_APP: run under nx-remote --app-from-fleet}"
out="${NX_ARTIFACTS:-$(mktemp -d)}/launch-guard"
mkdir -p "$out"
tag="$(basename "$app" .app)"; tag="${tag#cmux DEV }"
display="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|UI Looks like|Retina|Main Display' | sed 's/^ *//' | tr '\n' ';')"
echo "LAUNCH-GUARD-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) account=$(id -un) console=$(stat -f%Su /dev/console) tree=$(git rev-parse HEAD) app=\"$app\" model=$(sysctl -n hw.model) macos=$(sw_vers -productVersion) build=$(sw_vers -buildVersion) display=\"$display\" load=\"$(sysctl -n vm.loadavg)\""
budget=(--launch-guard --hangs 50 --budget first_window_frame_committed=150)
for suite in ${suites//,/ }; do
  case "$suite" in
    light|light-warm)
      modes=(--mode warm --mode kept); [[ "$suite" == light-warm ]] && modes=(--mode warm)
      echo "=== LIGHT $tag ${modes[*]}"
      python3 scripts/cmux-next/bench-startup.py --app "$app" --profile realistic "${modes[@]}" --runs "$runs" "${budget[@]}" \
        --json "$out/light-$tag.json" 2>&1 | tee "$out/light-$tag.log"
      echo "LAUNCH-GUARD-RESULT suite=light tag=$tag exit=${PIPESTATUS[0]}"
      ;;
    stress)
      for mode in warm kept; do
        quit=keep; [[ "$mode" == kept ]] && quit=end-sessions
        echo "=== STRESS $tag $mode (prime quit: $quit)"
        python3 scripts/measure/launch-guard-stress-prime.py --app "$app" --out "$out/stress-prime-$mode" --quit "$quit" 2>&1 \
          | tee "$out/stress-prime-$mode.log" | grep -E '^(STRESS-SESSION|STRESS-CEF|stress prime:|activation-perf:|Traceback|.*Error)'
        echo "STRESS-PRIME tag=$tag mode=$mode exit=${PIPESTATUS[0]}"
        python3 scripts/cmux-next/bench-startup.py --app "$app" --mode "$mode" --runs "$runs" "${budget[@]}" \
          --json "$out/stress-$mode-$tag.json" 2>&1 | tee "$out/stress-$mode-$tag.log"
        echo "LAUNCH-GUARD-RESULT suite=stress-$mode tag=$tag exit=${PIPESTATUS[0]}"
      done
      ;;
    *) echo "nx-launch-guard.sh: unknown suite $suite" >&2; exit 2 ;;
  esac
done
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
