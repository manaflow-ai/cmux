#!/usr/bin/env bash
# Live code in the app, end to end on a fleet Mac (Packages/macOS/CmuxNext/Sources/CmuxNextLiveCode):
# builds the bench configuration as a live code build (scripts/live-code/build.sh), launches it with
# a live folder (it opens on Home), then edits HomeHostView.updateLayer: Home's background red (the
# first patch also insets Home's transcript in HomeHostView.layout, which otherwise covers it), then
# blue, then red again as a bad patch, which a dropped `*.rollback` file undoes (blue again).
# Each edit is compiled into a patch (scripts/live-code/patch.py) and timed from the edit to the
# redraw, the rollback from the drop to the redraw; each generation's window snapshot is counted
# for red and blue pixels (cmuxterm-hq#7149 L3 and L4).
# --compare also builds the same commit's normal bench app and launches it the same way: the live
# code build's cost (binary size, launch to a socket answer) lands in OUT/compare.json.
#   scripts/measure/live-code-app.sh OUT [--compare]   (OUT: the logs, the snapshots and result.json)
set -euo pipefail
out="$(mkdir -p "${1:?usage: live-code-app.sh OUT}" && cd "$1" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
tag="live-code"
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
build_start=$SECONDS
app="$(scripts/live-code/build.sh "$out" "$tag" bench CMUX_DEV_BACKEND_MODE=local | tail -n 1)"
log="$out/xcodebuild.log"
status=0
python3 scripts/measure/live-code-app.py --app "$app" --log "$log" --out "$out" --build-seconds "$((SECONDS - build_start))" || status=$?
if [[ "${2:-}" == "--compare" ]]; then
  ./scripts/reload.sh --tag live-code-base --config bench > "$out/reload-base.log" 2>&1 || true
  base="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload-base.log" | tail -n 1)"
  python3 - "$app" "$base" "$out" <<'PY'
import json, os, sys
sys.path.insert(0, "scripts/cmux-next")
from bench_launch import BenchApp
live, base, out = sys.argv[1], sys.argv[2], sys.argv[3]
def measure(app, tag):
    exe = os.path.join(app, "Contents/MacOS/cmux")
    os.makedirs(os.path.join(out, tag), exist_ok=True)
    bench = BenchApp(app, out=os.path.join(out, tag))
    try:
        bench.launch()
        return {"binary_bytes": os.path.getsize(exe), "ready_s": bench.ready_seconds}
    finally:
        bench.stop()
compare = {"live_code": measure(live, "compare-live"), "normal": measure(base, "compare-normal") if base else None}
json.dump(compare, open(os.path.join(out, "compare.json"), "w"), indent=2)
print("live-code-app: compare " + json.dumps(compare))
PY
fi
exit "$status"
