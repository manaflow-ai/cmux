#!/usr/bin/env bash
# sign-cef.sh signs the embedded Chromium engine inside out and exits 0, with
# and without the Chromium host app. Release, RC and NIGHTLY bundles have no
# host app (embed-cef.sh adds it to Debug builds only): f8d6cd0139e ended its
# host loop with a bare `[[ -d ]] && codesign`, so sign-cef.sh exited 1 for
# every such bundle and failed every nightly-next build (fixed in 7670c8d5be7).
# codesign is a stand-in on PATH that logs its arguments, so this needs no
# signing identity and no real Mach-O.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# sign-cef.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sign-cef-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/codesign" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODESIGN_LOG"
STUB
chmod +x "$TMP/bin/codesign"

bundle() { # <dir> [host]: an app with the engine, the shim, three helpers and, with "host", the host app
  local fw="$1/app.app/Contents/Frameworks" helper
  mkdir -p "$fw/Chromium Embedded Framework.framework/Versions/A/Libraries"
  : > "$fw/Chromium Embedded Framework.framework/Versions/A/Libraries/libEGL.dylib"
  : > "$fw/libcmux_cef_shim.dylib"
  for helper in "app Helper" "app Helper (GPU)" "app Helper (Renderer)"; do
    mkdir -p "$fw/$helper.app/Contents/MacOS"
  done
  if [[ "${2:-}" == host ]]; then mkdir -p "$fw/app Chromium Host.app/Contents/MacOS"; fi
}
sign() { # <dir>: sign-cef.sh with identity "-"; its exit status
  CODESIGN_LOG="$1/codesign.log" PATH="$TMP/bin:/usr/bin:/bin" /bin/bash "$ROOT/scripts/cmux-next/sign-cef.sh" "$1/app.app" -
}

# 1. No host app (Release, RC, NIGHTLY).
mkdir "$TMP/release"
bundle "$TMP/release"
status=0
sign "$TMP/release" || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a bundle with no Chromium host app"
log="$(cat "$TMP/release/codesign.log")"
grep -q '/libEGL.dylib$' <<<"$log" || fail "the framework's libraries were not signed: $log"
grep -q 'Chromium Embedded Framework.framework$' <<<"$log" || fail "the framework was not signed: $log"
grep -q '/libcmux_cef_shim.dylib$' <<<"$log" || fail "the shim was not signed: $log"
grep -q -- '--entitlements .*app Helper (GPU).app$' <<<"$log" || fail "the GPU helper lost its JIT entitlements: $log"
grep -q -- '--entitlements .*app Helper (Renderer).app$' <<<"$log" || fail "the renderer helper lost its JIT entitlements: $log"
grep -q 'app Helper.app$' <<<"$log" || fail "the base helper was not signed: $log"
if grep -q 'Chromium Host' <<<"$log"; then fail "a host app was signed in a bundle without one: $log"; fi

# 2. With the host app (Debug): signed last, after its helpers, without entitlements.
mkdir "$TMP/debug"
bundle "$TMP/debug" host
status=0
sign "$TMP/debug" || status=$?
(( status == 0 )) || fail "sign-cef.sh exited $status for a bundle with the Chromium host app"
last="$(tail -n 1 "$TMP/debug/codesign.log")"
[[ "$last" == *"app Chromium Host.app" && "$last" != *--entitlements* ]] || fail "the host app was not signed last without entitlements: $last"

echo "sign-cef tests: ok"
