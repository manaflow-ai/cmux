#!/usr/bin/env bash
# A live code build (docs/cmux-next/live-code.md): the app built with CMUX_LIVE_CODE_BUILD=1, then
# linked again with only the CmuxNext symbols it exports made interposable. One pass is not
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
# 2. Interposable: what the app exports of the CmuxNext modules (lib/two-pass.sh). Then link again
# with that list: only the link step reruns.
# shellcheck source=scripts/live-code/lib/two-pass.sh
source scripts/live-code/lib/two-pass.sh
live_code_list "$bin" "$out"
app="$(reload "$out/reload-2.log" "$@" CMUX_LIVE_CODE_INTERPOSABLE_LIST="$out/interposable.txt")"
[[ -n "$app" && -d "$app" ]] || fail_build "$out/reload-2.log"
live_code_check "$bin" "$out" || exit 1
# Whether the CmuxNext modules compiled a file at a time, as the live build asks.
echo "live-code build: CmuxNextApp frontend commands: $(grep -cE -- "-module-name CmuxNextApp " "$log" || true), whole-module: $(grep -E -- "-module-name CmuxNextApp " "$log" | grep -c -- "-whole-module-optimization" || true)" >&2
echo "live-code build: built in $((SECONDS - build_start)) s"
grep -E -- "-module-name CmuxNext[A-Za-z0-9_]* " "$log" > "$out/cmuxnext-commands.log" || true
printf '%s\n' "$app" > "$out/app-path"
echo "$app"
