#!/usr/bin/env bash
# Sidebar stress at 1x and at scale, customization included, on a fleet Mac: builds a tagged cmux-next app (bench
# config: Release optimization with the debug.* control commands kept) at this checkout, then runs
# scripts/cmux-next/sidebar-stress-bench.py against it once per profile, each a fresh launch:
#   1x     20 workspaces in 1 group, custom sections 1, 10, 50
#   scale  500 workspaces in 50 groups, custom sections 50
# Each profile runs scroll, switch, theme_scroll (theme switches during a scroll) and custom_sections (scroll,
# switch and save-to-render with N sidebar sections). Prints the bench's `SIDEBAR_STRESS {json}` rows and writes
# sidebar-stress.json (every profile's results, no traces) in the checkout for --artifact.
# Runs alone on the worker because it launches an app:
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
reload_config=(--config bench) bench_args=() profiles="1x,scale"
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --profiles=*) profiles="${arg#--profiles=}" ;;
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
scenarios="scroll,switch,theme_scroll,custom_sections"
failed=0
IFS=, read -r -a profile_list <<<"$profiles"
for profile in "${profile_list[@]}"; do
  case "$profile" in
    1x) args=(--sizes 20 --groups 1 --custom-sections 1,10,50) ;;
    scale) args=(--sizes 500 --groups 50 --custom-sections 50) ;;
    *) echo "sidebar-stress: unknown profile $profile (1x, scale)" >&2; exit 2 ;;
  esac
  echo "sidebar-stress: profile $profile: ${args[*]}"
  # One profile that fails does not stop the next (each launches its own app); the step fails at the end.
  CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/sidebar-stress-bench.py --app "$app" --tag "$tag" \
    --out "$out/$profile" --scenarios "$scenarios" --tickers 1 --stop "${args[@]}" "$@" \
    || { echo "sidebar-stress: profile $profile exited non-zero" >&2; failed=1; }
done
python3 - "$out" "$PWD/sidebar-stress.json" "$profiles" <<'PY'
import json, os, sys
out, dest, profiles = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
merged = {}
for profile in profiles:
    path = os.path.join(out, profile, "results.json")
    merged[profile] = json.load(open(path)) if os.path.exists(path) else {"error": "no results.json"}
json.dump(merged, open(dest, "w"), indent=1, default=str)
print(f"sidebar-stress: wrote {dest} ({os.path.getsize(dest)} bytes)")
PY
exit "$failed"
