#!/usr/bin/env bash
# Browser-use primitive bench, no model (plans/cmux-next/browser-use-perf.md): cmux's browser host REPL
# against browser-use, Playwright MCP and Stagehand on the same live pages and the same headless Chrome.
# Measures only, never fails on a number (no gate). Run alone on an idle worker:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/browser-use-perf.sh \
#     --ref SHA [--arg=runs=20] [--arg=cold=20] [--arg=youtube=10] [--arg=tools=cmux,...] \
#     --artifact browser-use-perf.json --timeout 7200
# build=only: only the release cmux-browser-host at this ref, returned as an artifact for a run on
# another Mac (--class isolated --arg=build=only --artifact cmux-browser-host-release).
# Builds cmux-browser-host at this ref (release, as the app bundles it), installs the competitors at pinned
# versions under the step (tests/automation-bench/perf/setup.sh), and uses /Applications/Google Chrome.app
# when present, else Chrome for Testing through playwright-core. Output: BROWSER-USE-PERF lines (one per
# tool x site x primitive) and browser-use-perf.json (summaries and every row).
set -euo pipefail
runs=20
cold=20
youtube=10
tools="cmux,cmux-cli,cmux-tuned,browser-use,pwmcp,stagehand"
build_only=false
for arg in "$@"; do
  case "$arg" in
    build=only) build_only=true ;;
    runs=*) runs="${arg#runs=}" ;;
    cold=*) cold="${arg#cold=}" ;;
    youtube=*) youtube="${arg#youtube=}" ;;
    tools=*) tools="${arg#tools=}" ;;
    *) echo "browser-use-perf.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
for n in "$runs" "$cold" "$youtube"; do
  [[ "$n" =~ ^[0-9]{1,3}$ ]] || { echo "browser-use-perf.sh: runs, cold and youtube are 0-999" >&2; exit 2; }
done
[[ "$tools" =~ ^[a-z-]+(,[a-z-]+)*$ ]] || { echo "browser-use-perf.sh: tools=a,b,c" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/browser-use-perf"
rm -rf "$work"
mkdir -p "$work/bin" "$work/out"
echo "BROWSER-USE-PERF-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) model=$(sysctl -n hw.model) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD) load=\"$(sysctl -n vm.loadavg)\""

# The build scripts run Cargo only on a build host; this step is one.
export CI=1
git submodule update --init --depth 1 ghostty-next
(cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-browser-host)
cp "$work/target/release/cmux-browser-host" "$work/bin/cmux-browser-host"
if [[ "$build_only" == true ]]; then
  # The release host at this ref for a bench run elsewhere (cmux-ci artifact STEP OUTPUT);
  # no Cargo on the developer Mac. Nothing is measured here.
  cp "$work/bin/cmux-browser-host" "$root/cmux-browser-host-release"
  echo "BROWSER-USE-PERF-BUILD $(shasum -a 256 "$root/cmux-browser-host-release" | awk '{print $1}')"
  exit 0
fi

tests/automation-bench/perf/setup.sh "$work/deps"

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$chrome" ]]; then
  export PLAYWRIGHT_BROWSERS_PATH="$work/ms-playwright"
  node "$work/deps/playwright-mcp/node_modules/playwright-core/cli.js" install chromium >/dev/null
  chrome="$(find "$PLAYWRIGHT_BROWSERS_PATH" -path '*MacOS/Google Chrome for Testing' -type f | head -n 1)"
  [[ -x "$chrome" ]] || { echo "browser-use-perf.sh: no Chrome found or installed" >&2; exit 1; }
fi
echo "BROWSER-USE-PERF-CHROME $("$chrome" --version)"

bench=(python3 -I tests/automation-bench/perf/bench.py --deps "$work/deps" --chrome "$chrome" --bin "$work/bin" --tools "$tools")
status=0
[[ "$runs" != 0 ]] && { "${bench[@]}" --runs "$runs" --out "$work/out" | sed 's/^/BROWSER-USE-PERF warm /' || status=1; }
[[ "$cold" != 0 ]] && { "${bench[@]}" --cold "$cold" --out "$work/out" | sed 's/^/BROWSER-USE-PERF cold /' || status=1; }
yt_tools="$(tr ',' '\n' <<<"$tools" | grep -v -e '^cmux-cli$' -e '^cmux-tuned$' | paste -sd, -)"
[[ "$youtube" != 0 ]] && { "${bench[@]}" --tools "$yt_tools" --task youtube --runs "$youtube" --out "$work/out" | sed 's/^/BROWSER-USE-PERF youtube /' || status=1; }
echo "BROWSER-USE-PERF-LOAD end $(sysctl -n vm.loadavg)"
python3 -I - "$work/out" "$root/browser-use-perf.json" <<'PY'
import glob, json, os, sys
out, dest = sys.argv[1], sys.argv[2]
merged = {}
for path in sorted(glob.glob(os.path.join(out, "*-summary.json")) + glob.glob(os.path.join(out, "*-rows.jsonl"))):
    name = os.path.basename(path)
    with open(path) as f:
        merged[name] = json.load(f) if name.endswith(".json") else [json.loads(line) for line in f]
with open(dest, "w") as f:
    json.dump(merged, f)
PY
exit "$status"
