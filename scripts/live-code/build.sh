#!/usr/bin/env bash
# A live code build (docs/cmux-next/live-code.md): the app built with CMUX_LIVE_CODE_BUILD=1, then
# linked again with only the CmuxNextApp symbols it exports made interposable. One pass is not
# enough: CMUX_LIVE_CODE_BUILD alone builds an app no patch can repoint, and a blanket
# -interposable stops it at launch (a private type's symbol dyld cannot bind).
#   scripts/live-code/build.sh OUT [TAG [CONFIG]] [ENV=VALUE...]
# OUT gets xcodebuild.log (the full build's log, which scripts/live-code/patch.py compiles patches
# from), interposable.txt and app-path; the last line printed is the app's path. TAG defaults to
# live-code, CONFIG to Debug (bench for the fleet's measurement); ENV=VALUE pairs go to reload.sh.
set -euo pipefail
out="$(mkdir -p "${1:?usage: build.sh OUT [TAG [CONFIG]] [ENV=VALUE...]}" && cd "$1" && pwd)"; shift
tag="live-code"; config="debug"
if [[ $# -gt 0 && "$1" != *=* ]]; then tag="$1"; shift; fi
if [[ $# -gt 0 && "$1" != *=* ]]; then config="$1"; shift; fi
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
build_start=$SECONDS
reload() { # LOG [ENV=VALUE...]: one live code build; prints the app path
  local log="$1"; shift
  # A failed build is reported below, from its log, so the pipeline's status is not the step's.
  env "$@" CMUX_LIVE_CODE_BUILD=1 ./scripts/reload.sh --tag "$tag" --config "$config" 2>&1 | tee "$log" >&2 || true
  sed -n '/^App path:/{n;s/^ *//;p;}' "$log" | tail -n 1
}
fail_build() {
  echo "live-code build: the reload printed no app path" >&2
  local build_log; build_log="$(sed -n 's/^==> log: //p' "$1" | tail -n 1)"
  [[ -n "$build_log" && -f "$build_log" ]] && grep -E "\.swift:[0-9]+:[0-9]+: error|error: " "$build_log" | head -n 40 >&2
  exit 1
}
# 1. Build and link, nothing interposable yet.
app="$(reload "$out/reload.log" "$@")"
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
echo "live-code build: $(wc -l < "$list" | tr -d ' ') CmuxNextApp symbols in the export trie, $(wc -l < "$out/nm-exported.txt" | tr -d ' ') external in the symbol table"
private_probe='_$s11CmuxNextApp11FlippedView'
echo "live-code build: FlippedView in the trie: $(grep -c "^$private_probe" "$list" || true), in nm -g: $(grep -c "^$private_probe" "$out/nm-exported.txt" || true)"
nm -m "$bin" | grep -F "FlippedView" > "$out/flipped-nm.txt" || true
sed -n 1,5p "$out/flipped-nm.txt"
[[ -s "$list" ]] || { echo "live-code build: the app exports no CmuxNextApp symbol (LD_EXPORT_SYMBOLS?)" >&2; exit 1; }
app="$(reload "$out/reload-2.log" "$@" CMUX_LIVE_CODE_INTERPOSABLE_LIST="$list")"
[[ -n "$app" && -d "$app" ]] || fail_build "$out/reload-2.log"
# Every symbol the relinked app binds from itself must be in its own export trie, or dyld stops the
# launch; name the first few that are not.
xcrun dyld_info -exports "$bin" | grep -oE '_\$s11CmuxNextApp[^ ]*' | sort -u > "$out/exports-2.txt" || true
xcrun dyld_info -fixups "$bin" | grep -oE '_\$s11CmuxNextApp[^ ]*' | sort -u > "$out/binds-2.txt" || true
comm -23 "$out/binds-2.txt" "$out/exports-2.txt" > "$out/missing-2.txt"
missing="$(sed -n 1,5p "$out/missing-2.txt")"
echo "live-code build: relinked: $(wc -l < "$out/binds-2.txt" | tr -d ' ') CmuxNextApp binds, $(wc -l < "$out/exports-2.txt" | tr -d ' ') exported"
# dyld_info -fixups also names the target of a rebase, which needs no export: print the fixup lines
# themselves, and leave the verdict to the launch (dyld says "Symbol not found" for a real bind).
if [[ -n "$missing" ]]; then
  echo "live-code build: $(wc -l < "$out/missing-2.txt" | tr -d ' ') CmuxNextApp symbols named by a fixup are not exported; their fixups:" >&2
  xcrun dyld_info -fixups "$bin" | grep -F -f <(sed -n 1,5p "$out/missing-2.txt") | head -n 10 >&2 || true
fi
# Whether CmuxNextApp compiled a file at a time (reload.sh's live build) or whole-module.
wmo="$(grep -E -- "-module-name CmuxNextApp " "$log" | grep -c -- "-whole-module-optimization" || true)"
echo "live-code build: CmuxNextApp frontend commands: $(grep -cE -- "-module-name CmuxNextApp " "$log" || true), whole-module: $wmo"
echo "live-code build: built in $((SECONDS - build_start)) s"
grep -E -- "-module-name CmuxNextApp " "$log" > "$out/cmuxnextapp-commands.log" || true
printf '%s\n' "$app" > "$out/app-path"
echo "$app"
