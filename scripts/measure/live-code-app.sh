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
# The list comes from the export trie dyld binds from, not the symbol table: nm -g also lists a
# file's private symbols (a private type's deinit, say), and a bind to one of those fails at launch.
list="$out/interposable.txt"
xcrun dyld_info -exports "$bin" | grep -oE '_\$s11CmuxNextApp[^ ]*' | sort -u > "$list" || true
nm -gUj "$bin" | grep -E '^_\$s11CmuxNextApp' | sort -u > "$out/nm-exported.txt" || true
echo "live-code-app: $(wc -l < "$list" | tr -d ' ') CmuxNextApp symbols in the export trie, $(wc -l < "$out/nm-exported.txt" | tr -d ' ') external in the symbol table"
private_probe='_$s11CmuxNextApp11FlippedView'
echo "live-code-app: FlippedView in the trie: $(grep -c "^$private_probe" "$list" || true), in nm -g: $(grep -c "^$private_probe" "$out/nm-exported.txt" || true)"
nm -m "$bin" | grep -F "FlippedView" > "$out/flipped-nm.txt" || true
sed -n 1,5p "$out/flipped-nm.txt"
[[ -s "$list" ]] || { echo "live-code-app: the app exports no CmuxNextApp symbol (LD_EXPORT_SYMBOLS?)" >&2; exit 1; }
app="$(reload "$out/reload-2.log" CMUX_LIVE_CODE_INTERPOSABLE_LIST="$list")"
[[ -n "$app" && -d "$app" ]] || fail_build "$out/reload-2.log"
# Every symbol the relinked app binds from itself must be in its own export trie, or dyld stops the
# launch; name the first few that are not.
xcrun dyld_info -exports "$bin" | grep -oE '_\$s11CmuxNextApp[^ ]*' | sort -u > "$out/exports-2.txt" || true
xcrun dyld_info -fixups "$bin" | grep -oE '_\$s11CmuxNextApp[^ ]*' | sort -u > "$out/binds-2.txt" || true
comm -23 "$out/binds-2.txt" "$out/exports-2.txt" > "$out/missing-2.txt"
missing="$(sed -n 1,5p "$out/missing-2.txt")"
echo "live-code-app: relinked: $(wc -l < "$out/binds-2.txt" | tr -d ' ') CmuxNextApp binds, $(wc -l < "$out/exports-2.txt" | tr -d ' ') exported"
[[ -z "$missing" ]] || { echo "live-code-app: the relinked app binds $(wc -l < "$out/missing-2.txt" | tr -d ' ') CmuxNextApp symbols it does not export, first:" >&2; echo "$missing" >&2; exit 1; }
echo "live-code-app: built in $((SECONDS - build_start)) s"
# The patch compiles from this log; keep CmuxNextApp's lines with the results.
grep -E -- "-module-name CmuxNextApp " "$log" > "$out/cmuxnextapp-commands.log" || true
python3 scripts/measure/live-code-app.py --app "$app" --log "$log" --out "$out" --build-seconds "$((SECONDS - build_start))"
