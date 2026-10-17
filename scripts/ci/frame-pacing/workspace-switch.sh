#!/usr/bin/env bash
# Workspace-switch readiness bench for the tagged cmux-next app.
#
# usage: workspace-switch.sh WORK_DIR SOURCE_SHA HARNESS_SHA [RUNS]
#   WORK_DIR holds app/*.app and the bench output directory. The script runs in
#   the console user's GUI session via console-session.sh and writes one receipt
#   at out/workspace-switch.json.
set -euo pipefail

work="${1:?usage: workspace-switch.sh WORK_DIR SOURCE_SHA HARNESS_SHA [RUNS]}"
source_sha="${2:?usage: workspace-switch.sh WORK_DIR SOURCE_SHA HARNESS_SHA [RUNS]}"
harness_sha="${3:?usage: workspace-switch.sh WORK_DIR SOURCE_SHA HARNESS_SHA [RUNS]}"
runs="${4:-3}"
tag="${CMUX_TAG:?set CMUX_TAG to the baked tag of the app}"
app="$(ls -d "$work"/app/*.app 2>/dev/null | head -1)"
[ -n "$app" ] || { echo "no app under $work/app" >&2; exit 1; }

mkdir -p "$work/out"
python3 scripts/cmux-next/bench_workspace_switch.py \
  --tag "$tag" \
  --app "$app" \
  --sha "$source_sha" \
  --harness-sha "$harness_sha" \
  --runs "$runs" \
  --out "$work/out/workspace-switch.json"
