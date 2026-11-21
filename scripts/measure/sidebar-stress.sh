#!/usr/bin/env bash
# Sidebar stress at 1x and at scale, customization included, on a fleet Mac: builds a tagged cmux-next app (bench
# config: Release optimization with the debug.* control commands kept) at this checkout, then runs
# scripts/cmux-next/sidebar-stress-profiles.py against it (sidebar-stress-bench.py once per profile, each a fresh
# launch: 1x = 20 workspaces in 1 group with 1, 10, 50 custom sections; scale = 500 workspaces in 50 groups with 50).
# Writes sidebar-stress.json (every profile's results, no traces) in the checkout for --artifact.
# Runs alone on the worker because it launches an app. An unlisted measure script runs only at a commit on
# feat-cmux-next or main; at a PR head use split-spring.sh --arg=--suite=sidebar-stress (same driver):
#   cmux-ci run --class exclusive --label measure --measurement --display --script scripts/measure/sidebar-stress.sh \
#     --ref <sha> --artifact sidebar-stress.json [--arg=--profiles=1x,scale] [--arg=--no-trace]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="sbstress"
out="$(mktemp -d)"
# Remove the scratch folder on every exit (a failed build, a TERM), not only at the end: a leaked one holds a build.
trap 'rm -rf -- "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
reload_config=(--config bench) bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" >"$out/reload.log" 2>&1 \
  || { tail -n 40 "$out/reload.log" >&2; grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "sidebar-stress: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "sidebar-stress: ref $(git rev-parse HEAD) host $(hostname -s) macOS $(sw_vers -productVersion 2>/dev/null || echo ?)"
python3 scripts/cmux-next/sidebar-stress-profiles.py --tag "$tag" --app "$app" --out "$out" \
  --json "$PWD/sidebar-stress.json" "$@"
