#!/usr/bin/env bash
# check-no-bench-hooks.sh and the nightly-assert variant (p10-stability-202): an app whose main executable has
# the INVARIANT_REPORT marker fails without --invariant-report (the release, RC and main nightly pipelines);
# with it, the marker must be there and the bundle must not be Release or RC. macOS only (PlistBuddy).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-no-bench-hooks.sh"
if [[ ! -x /usr/libexec/PlistBuddy ]]; then
  echo "skip: check-no-bench-hooks.sh reads Info.plist with /usr/libexec/PlistBuddy (macOS)"
  exit 0
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-invariant-report.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
invariant_marker="CMUX_INVARIANT_REPORT""_BUILD: debug checks and assert() report once per site"
bench_marker="CMUX_BENCH_HOOKS""_BUILD: debug control commands"

# app BUNDLE_ID EXECUTABLE_TEXT: makes $tmp/app/cmux.app with that bundle id and main executable text.
app() {
  rm -rf "$tmp/app"
  mkdir -p "$tmp/app/cmux.app/Contents/MacOS"
  cat > "$tmp/app/cmux.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>cmux</string>
  <key>CFBundleIdentifier</key><string>$1</string>
</dict>
</plist>
PLIST
  printf '%s\n' "$2" > "$tmp/app/cmux.app/Contents/MacOS/cmux"
}
pass() {
  local why="$1"; shift
  "$CHECK" "$@" "$tmp/app/cmux.app" >/dev/null 2>"$tmp/err" || { echo "FAIL: must pass: $why" >&2; cat "$tmp/err" >&2; exit 1; }
}
fail() {
  local why="$1"; shift
  local code=0
  "$CHECK" "$@" "$tmp/app/cmux.app" >/dev/null 2>"$tmp/err" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail (got $code): $why" >&2; cat "$tmp/err" >&2; exit 1; }
}

app com.cmuxterm.app.nightly "plain"
pass "a shipped app without the marker"
fail "--invariant-report needs the marker" --invariant-report

app com.cmuxterm.app.nightly "$invariant_marker"
fail "the main nightly refuses a nightly-assert app"
pass "the sampled Nightly slice's build" --invariant-report

app com.cmuxterm.app "$invariant_marker"
fail "Release refuses a nightly-assert app"
fail "Release refuses --invariant-report" --invariant-report

app com.cmuxterm.app.rc "$invariant_marker"
fail "RC refuses a nightly-assert app"
fail "RC refuses --invariant-report" --invariant-report

app com.cmuxterm.app.debug.nightly-assert "$bench_marker $invariant_marker"
pass "a bench nightly-assert tagged build" --expect --invariant-report
fail "a bench build without --invariant-report" --expect

echo "check-no-bench-hooks invariant report: ok"
