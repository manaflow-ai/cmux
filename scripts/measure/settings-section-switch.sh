#!/usr/bin/env bash
# Settings section switch (msg 8948, TanStack Router intent preload): the latency harness's Settings
# page (webviews/test/latency/settings.html, host delay 40 ms) in headless WebKit and Chromium. Per
# engine and action ("section switch (click)", "section switch (hover, then click)") it prints one
# `SETTINGS_SWITCH {json}` line: p50 and p95 from the click to the first painted frame showing the
# new section complete, and the runs. Run alone on a worker, once per commit to compare:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/settings-section-switch.sh --ref SHA
# CMUX_SETTINGS_SWITCH_RUNS: runs per action and engine (default 40).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
bun_pin="$(python3 -c 'import json; print(json.load(open("webviews/package.json"))["devEngines"]["packageManager"]["version"])')"
bun_dir="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/tools/bun-$bun_pin/bin"
if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ] && [ -x "$bun_dir/bun" ]; then
  export PATH="$bun_dir:$PATH"
fi
cd webviews
bun install --frozen-lockfile
playwright_version="$(python3 -c 'import json; print(json.load(open("package.json"))["devDependencies"]["playwright"])' 2>/dev/null || echo unknown)"
export PLAYWRIGHT_BROWSERS_PATH="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/playwright-$playwright_version"
./node_modules/.bin/playwright install --only-shell chromium webkit
echo "host: $(hostname) sha: $(git rev-parse HEAD) bun: $(bun --version)"
out="$(mktemp -d)/settings-switch.json"
bun scripts/latency/run.ts --page settings --runs "${CMUX_SETTINGS_SWITCH_RUNS:-40}" --no-fail --json "$out"
python3 -I - "$out" <<'PY'
import json, sys
def pct(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))], 1)
data = json.load(open(sys.argv[1]))
results = data["results"] if isinstance(data, dict) and "results" in data else data
for result in results:
    paints = [sample["paint"] for sample in result.get("samples", [])]
    print("SETTINGS_SWITCH " + json.dumps({
        "engine": result["engine"], "action": result["action"], "runs": len(paints),
        "timeouts": result.get("timeouts", 0), "p50_ms": pct(paints, 50), "p95_ms": pct(paints, 95),
        "max_ms": max(paints) if paints else None, "errors": result.get("errors", [])[:2],
    }))
PY
