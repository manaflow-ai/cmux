#!/usr/bin/env bash
# Fleet entry for page-heap-report.py (plans/cmux-next/chrome-parity/p07-memory.md, task 102, MQ-JSHEAP):
# builds a tagged cmux-next app at this checkout, launches it with a scratch HOME and config, measures the
# JS heap of every live cmux page at Home idle, then opens answered agent chats on the fake ACP agent and
# measures again after 50 workspace switches between them. Prints one table per phase, PAGE-HEAP and
# MQ-JSHEAP lines (a page above 20 MB of JS heap, or grown by more than 5 MB over the switches), each with
# the top retainers of that page's heap snapshot under it; the JSON report and the heap snapshots land in
# artifacts/page-heap/.
#
# --config=debug (default) opens Chromium's DevTools port (CMUX_NEXT_CEF_EXTRA_SWITCHES, DEBUG builds only),
# so each Chromium page gets Runtime.getHeapUsage, and each page with an MQ-JSHEAP line a heap snapshot in the
# last phase (--snapshot flagged; --arg=--snapshot=all snapshots every page, --arg=--snapshot=none none). The
# pages run the same web bundles in every configuration (build-web-bundles.sh). --config=bench (Release
# optimization) has no DevTools port: pages are then measured by their renderer and WebContent processes,
# which debug.webui names by page.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/page-heap-report.sh \
#     --ref <sha> --artifact artifacts/page-heap/report.json [--arg=--snapshot=none] [--arg=--config=bench]
# Every argument but --config=<debug|release|bench> goes to page-heap-report.py.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="pageheap"
out="$PWD/artifacts/page-heap"
mkdir -p "$out"
reload_config=(--config debug) report_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) report_args+=("$arg") ;;
  esac
done
echo "PAGE-HEAP-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) config=${reload_config[1]}"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links "${reload_config[@]}" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "page-heap-report: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
# A fleet step has no LaunchServices session: run the app binary itself (bench_memory.launch).
CMUX_BENCH_LAUNCH=direct python3 -I scripts/cmux-next/page-heap-report.py --app "$app" --phases home,switches \
  --switches 50 --snapshot flagged --out "$out/report.json" ${report_args[@]+"${report_args[@]}"}
