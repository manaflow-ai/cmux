#!/usr/bin/env bash
# The perf lab's webviews stories on Linux (scripts/perf-lab/stories.d/webviews.json and
# webviews-chromium.json): runs one engine's benches and perf tests with PERF_RESULT_DIR set, so each
# writes cmux-perf-result/v1 through scripts/perf-lab/perf_result.py (scripts/perf-result.mjs ->
# scripts/perf-lab/bench_results.py).
#
#   webviews/scripts/perf-lab-story.sh --engine none|chromium --out DIR [--app APP --tag TAG]
#
# --app and --tag are the story runner's flags (stories.d/README.md); these benches measure this
# checkout's webviews code and launch no app. All results of one call are one lab run
# (PERF_LAB_RUN_ID, PERF_LAB_RUN_STARTED_AT). A part that fails or writes no result fails the call;
# the other parts still run.
set -euo pipefail

engine="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) engine="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --app | --tag) shift 2 ;;
    *) echo "perf-lab-story: unknown option $1" >&2; exit 2 ;;
  esac
done
case "$engine" in
  none) story=webviews ;;
  chromium) story=webviews-chromium ;;
  *) echo "perf-lab-story: --engine is none or chromium" >&2; exit 2 ;;
esac
[[ -n "$out" ]] || { echo "perf-lab-story: --out DIR is required" >&2; exit 2; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"

export PERF_RESULT_DIR="$out"
export PERF_LAB_STORY="${PERF_LAB_STORY:-$story}"
PERF_LAB_RUN_ID="${PERF_LAB_RUN_ID:-$(python3 -I -c 'import uuid; print(uuid.uuid4().hex)')}"
PERF_LAB_RUN_STARTED_AT="${PERF_LAB_RUN_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
export PERF_LAB_RUN_ID PERF_LAB_RUN_STARTED_AT

cd "$(dirname "$0")/.."
bun install --frozen-lockfile > /dev/null

failed=0
results() { find "$out" -maxdepth 1 -name '*.ndjson' | wc -l; }
# part NAME COMMAND...: runs one bench and checks that it wrote a result-v1 file.
part() {
  local name="$1" before
  shift
  before="$(results)"
  if ! "$@"; then
    echo "perf-lab-story: $name failed" >&2
    failed=1
  fi
  if [[ "$(results)" -le "$before" ]]; then
    echo "perf-lab-story: $name wrote no result-v1 into $out" >&2
    failed=1
  fi
}

case "$engine" in
  none)
    part diff-stream env CMUX_DIFF_BENCH_RENDER_APP=1 bun run bench/diff-stream.bench.ts
    part settings env CMUX_SETTINGS_BENCH=1 bun test ./src/pages/settings/settingsPerf.test.tsx
    part ordered-rows bun test ./src/agent-session/acpmux/orderedRowsPerf.test.ts
    part icon-picker bun run bench/icon-picker/model-bench.ts
    ;;
  chromium)
    # A lab host is a browser-lane machine (test/support/requireBrowserLane.ts).
    export CMUX_BROWSER_TESTS=1
    part chat-open bun test ./test/chat-open-perf.test.ts
    part diff-paint bun test ./test/diff-paint-perf.test.ts
    ;;
esac
exit "$failed"
