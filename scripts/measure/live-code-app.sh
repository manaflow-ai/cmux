#!/usr/bin/env bash
# Live code in the app, end to end on a fleet Mac (Packages/macOS/CmuxNext/Sources/CmuxNextLiveCode):
# builds the bench configuration with CMUX_LIVE_CODE_BUILD=1, launches it with a live folder (it
# opens on Home), then edits HomeHostView.updateLayer twice (Home's background red, then blue),
# compiles each edit into a patch (scripts/live-code/patch.py) and times the edit to the redraw. The window's snapshots before and after each patch are counted for red and blue pixels.
#   scripts/measure/live-code-app.sh OUT     (OUT: the log, the snapshots and result.json)
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
reload() { # LOG [ENV=VALUE...]: one live code build; prints the app path
  local log="$1"; shift
  # A failed build is reported below, from its log, so the pipeline's status is not the step's.
  env "$@" CMUX_LIVE_CODE_BUILD=1 CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config bench 2>&1 | tee "$log" >&2 || true
  sed -n '/^App path:/{n;s/^ *//;p;}' "$log" | tail -n 1
}
fail_build() {
  echo "live-code-app: the reload printed no app path" >&2
  local build_log; build_log="$(sed -n 's/^==> log: //p' "$1" | tail -n 1)"
  [[ -n "$build_log" && -f "$build_log" ]] && grep -E "\.swift:[0-9]+:[0-9]+: error|error: " "$build_log" | head -n 40 >&2
  exit 1
}
# 1. Build and link, nothing interposable yet.
app="$(reload "$out/reload.log")"
[[ -n "$app" && -d "$app" ]] || fail_build "$out/reload.log"
# The full build's xcodebuild log holds the frontend commands a patch compiles with; the relink
# below writes a new one.
log="$out/xcodebuild.log"
cp "$(sed -n 's/^==> log: //p' "$out/reload.log" | tail -n 1)" "$log"
bin="$app/Contents/MacOS/cmux"
[[ -f "$bin" ]] || bin="$(find "$app/Contents/MacOS" -maxdepth 1 -type f ! -name '*.dylib' | head -n 1)"
# 2. Interposable: the CmuxNextApp symbols the app exports (what dyld can bind a call to). Then
# link again with that list: only the link step reruns.
list="$out/interposable.txt"
nm -gUj "$bin" | grep -E '^_\$s11CmuxNextApp' > "$list" || true
echo "live-code-app: $(wc -l < "$list" | tr -d ' ') exported CmuxNextApp symbols of $(nm -gUj "$bin" | wc -l | tr -d ' ') exported in all"
[[ -s "$list" ]] || { echo "live-code-app: the app exports no CmuxNextApp symbol (LD_EXPORT_SYMBOLS?)" >&2; exit 1; }
app="$(reload "$out/reload-2.log" CMUX_LIVE_CODE_INTERPOSABLE_LIST="$list")"
[[ -n "$app" && -d "$app" ]] || fail_build "$out/reload-2.log"
echo "live-code-app: built in $((SECONDS - build_start)) s"
# The patch compiles from this log; keep CmuxNextApp's lines with the results.
grep -E -- "-module-name CmuxNextApp " "$log" > "$out/cmuxnextapp-commands.log" || true
python3 scripts/measure/live-code-app.py --app "$app" --log "$log" --out "$out" --build-seconds "$((SECONDS - build_start))"
