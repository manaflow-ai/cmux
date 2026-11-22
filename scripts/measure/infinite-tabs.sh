#!/usr/bin/env bash
# Fleet entry for the infinite tabs bench (cmuxterm-hq goals/infinite-tabs-flat.md; Leo, 2026-11-22:
# "i also want us to keep pursuing the ability to have infinite fucking tabs and workspaces and shit
# without getting starved of cpu/ram. having ultra awesome hibernation"): builds a tagged cmux-next
# DEV app at this checkout, then runs scripts/cmux-next/bench_infinite_tabs.py: the app empty, then
# with 500 Chromium tabs, 200 workspaces and 100 agent chats, all but the front workspace hibernated
# (total RSS, footprint, idle CPU and wakeups over the empty app's, renderer memory per hibernated
# tab), then 20 hibernated tabs switched to and timed.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/infinite-tabs.sh --ref <sha> \
#     [--arg=--tabs=500] [--arg=--workspaces=200] [--arg=--chats=100] [--arg=--config=bench]
# To measure an older commit, cherry-pick the harness commits onto it (the script blobs must match the reviewed ones).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
. scripts/measure/require-chromium.sh
tag="inftabs"
out="$(mktemp -d)"
# Remove the scratch folder on every exit (a failed build, a TERM), not only at the end: a leaked one holds a build.
trap 'rm -rf -- "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# --config=<debug|release|bench> picks reload.sh's build configuration (bench: Release optimization with the
# debug.* control commands kept); every other argument goes to the bench.
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=debug|--config=release|--config=bench) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
# The tabs are Chromium pages: a build with no engine opens none of them, and the run measures another mix
# (step a985cca9a3ba on cmux19: tabs=0 of 500, after a 50 minute build and run).
reload_status=0
CMUX_NEXT_REQUIRE_CEF=1 CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log" || reload_status=$?
if [[ "$reload_status" -ne 0 ]]; then
  measure_chromium_failure infinite-tabs "$out/reload.log" || true
  exit "$reload_status"
fi
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "infinite-tabs: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "infinite-tabs: ref $(git rev-parse HEAD)"
# A fleet step has no LaunchServices session: run the app binary itself (bench_memory.launch).
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_infinite_tabs.py --app "$app" \
  --fake-agent "$PWD/cmux-tui/crates/acpmux/tests/fake_agent.py" --out "$PWD/infinite-tabs.json" "$@"
