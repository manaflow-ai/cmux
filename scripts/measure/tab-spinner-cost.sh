#!/usr/bin/env bash
# What the tab-strip spinner costs while a page's load never ends (no-hangs lane, hq#13463): builds a tagged app at
# this checkout, then runs scripts/cmux-next/browser-idle-cost-live.py twice on one build, phases static then loading
# (a background Chromium tab whose image request the server keeps open, so its strip spinner runs for as long as the
# window is awake): once with the spinner (the default), once with appearance.statusIndicator.showPageLoading off
# (the tab keeps its icon). The loading phase's difference between the two runs is the spinner's cost: app and GPU
# process CPU and wakeups, and WindowServer CPU (the spinner is a Core Animation loop the render server draws).
# Measures only; no gate. Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/tab-spinner-cost.sh \
#     --ref <sha> --artifact artifacts/tab-spinner-cost.json [--arg=--idle-s=60] [--arg=--rounds=2]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
rounds=2 bench_args=()
for arg in "$@"; do
  case "$arg" in
    --rounds=*) rounds="${arg#--rounds=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="tabspinner"
out="$PWD/artifacts/tab-spinner-cost"
mkdir -p "$out"
echo "TAB-SPINNER-COST-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) macos=$(sw_vers -productVersion)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config bench --no-global-cli-links 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "tab-spinner-cost: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
status=0
for round in $(seq 1 "$rounds"); do
  for arm in spinner still; do
    config='{}'
    [ "$arm" = still ] && config='{"appearance":{"statusIndicator":{"showPageLoading":false}}}'
    mkdir -p "$out/$arm-$round"
    CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/browser-idle-cost-live.py --app "$app" --tabs 2 --phases static,loading \
      --no-sample --config "$config" --out "$out/$arm-$round" ${bench_args[@]+"${bench_args[@]}"} || status=1
  done
done
python3 - "$out" "$rounds" > artifacts/tab-spinner-cost.json <<'PY'
import glob, json, os, sys
out, rounds = sys.argv[1], int(sys.argv[2])
runs = []
for path in sorted(glob.glob(os.path.join(out, "*-*", "browser-idle-cost-*.json"))):
    arm, round_ = os.path.basename(os.path.dirname(path)).rsplit("-", 1)
    data = json.load(open(path))
    for phase in data.get("phases", []):
        row = {"arm": arm, "round": int(round_), "phase": phase["phase"],
               "window_server_cpu_percent": phase.get("window_server_cpu_percent"),
               "total_cpu_percent": phase.get("total_cpu_percent")}
        for kind in ("app", "gpu", "renderer"):
            c = phase["classes"].get(kind, {})
            row[f"{kind}_cpu_percent"] = c.get("cpu_percent")
            row[f"{kind}_wakeups_per_s"] = c.get("wakeups_per_s")
        runs.append(row)
        print(json.dumps(row), file=sys.stderr)
json.dump({"rounds": rounds, "runs": runs}, sys.stdout, indent=1)
PY
exit "$status"
