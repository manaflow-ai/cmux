#!/usr/bin/env bash
# perf-10x settings bench (msg 1628): the Settings page (store, query cache, every component) over
# the mock provider in bun + jsdom. Per scenario it prints one `SETTINGS_BENCH {json}` line: wall
# time from the gesture to the settled page, React render time, components and setting rows
# rendered, and settings reads (cmux.settings.list) per gesture. Run alone on a worker:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/perf-10x-settings.sh --ref SHA
# CMUX_SETTINGS_BENCH_N: samples per scenario (default 40).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
bash scripts/ci/ensure-web-bundles.sh
bun_pin="$(python3 -c 'import json; print(json.load(open("webviews/package.json"))["devEngines"]["packageManager"]["version"])')"
bun_dir="${CMUX_CI_CACHE_DIR:-$HOME/Library/Caches/cmux-ci}/tools/bun-$bun_pin/bin"
if [ "$(bun --version 2>/dev/null || true)" != "$bun_pin" ] && [ -x "$bun_dir/bun" ]; then
  export PATH="$bun_dir:$PATH"
fi
cd webviews
bun install --frozen-lockfile
echo "host: $(hostname) sha: $(git rev-parse HEAD) bun: $(bun --version)"
CMUX_SETTINGS_BENCH=1 CMUX_SETTINGS_BENCH_N="${CMUX_SETTINGS_BENCH_N:-40}" \
  bun test ./src/pages/settings/settingsPerf.test.tsx 2>&1 | grep -E "SETTINGS_BENCH|pass|fail|error"
