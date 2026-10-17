#!/usr/bin/env bash
# Reuse the frame-pacing lane's downloaded tagged app and held GUI token.
# usage: workspace-switch.sh WORK_DIR SOURCE_SHA HARNESS_SHA [RUNS]
set -euo pipefail
work="${1:?pass the frame-pacing work directory}"
source_sha="${2:?pass the downloaded app source SHA}"
harness_sha="${3:?pass the benchmark harness SHA}"
runs="${4:-3}"
root="$(cd "$(dirname "$0")/../../.." && pwd)"
app="$work/app/cmux DEV ${CMUX_TAG:?set the downloaded app tag}.app"
exec python3 "$root/scripts/cmux-next/bench_workspace_switch.py" \
  --tag "$CMUX_TAG" --app "$app" --sha "$source_sha" --harness-sha "$harness_sha" \
  --out "$work/out/workspace-switch.json" --runs "$runs"
