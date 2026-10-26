#!/usr/bin/env bash
# Fleet entry for the WebUI bench (plans/cmux-next/chrome-parity/p13-webui.md, section 5: D1-D6, D12): builds a
# tagged cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench-webui.py once per mode. Not a gate:
# rows print measured values beside their targets; the exit is non-zero only when a run refused its session shape (2)
# or could not run. Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/webui-bench.sh --ref <sha> \
#     --artifact artifacts/webui-bench [--arg=--modes=home,open] [--arg=--engine=webkit] [--arg=--session=stress]
#     [--arg=--config=bench]
#   MQ5's hidden-page wakeups (task 037): --arg=--modes=pages10 --arg=--every-page-hidden (freezing off)
#   Task 052's code cache arm (Debug build on the spike's fork pin): --arg=--modes=open --arg=--page-code-cache
# --modes (default home,pages10,open,crash,pressure,priority) and --config=<debug|release|bench> (reload.sh's build
# configuration; bench keeps the debug.* control methods in a Release build) are this script's; every other argument
# goes to each bench run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes from the pinned
# cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="webuibench"
out="$PWD/artifacts/webui-bench"
mkdir -p "$out"
modes="home,pages10,open,crash,pressure,priority"
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --modes=*) modes="${arg#--modes=}" ;;
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
echo "WEBUI-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
build_errors() {
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
}
if ! CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links ${reload_config[@]+"${reload_config[@]}"} 2>&1 \
  | tee "$out/reload.log" | tail -n 40; then
  echo "webui-bench: the tagged reload failed" >&2
  build_errors
  exit 1
fi
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "webui-bench: the tagged reload printed no app path" >&2
  build_errors
  exit 1
fi
status=0
IFS=',' read -r -a mode_list <<<"$modes"
for mode in "${mode_list[@]}"; do
  echo "webui-bench: mode $mode"
  python3 scripts/cmux-next/bench-webui.py "$mode" --app "$app" --out "$out/$mode" ${bench_args[@]+"${bench_args[@]}"} \
    || status=$?
done
exit "$status"
