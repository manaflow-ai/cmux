#!/usr/bin/env bash
# drop-cef-without-arch.sh removes the Chromium engine from a thin variant
# whose architecture the engine lacks, and the Chromium host with it: the host
# is built for the engine's architectures only (embed-cef.sh), so a host left
# behind would fail scripts/thin-app-bundle.sh for that variant. With the
# slice, everything stays. lipo is a stand-in that reads the slice list from
# the file, so this runs on Linux.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# drop-cef-without-arch.sh or the host's place in the bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drop-cef-without-arch-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/lipo" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  -verify_arch) grep -qw "$3" "$1" ;;
  *) cat "$2" ;;
esac
STUB
chmod +x "$TMP/bin/lipo"

bundle() { # <dir>: an app whose engine and host are arm64 only
  local app="$1/app.app"
  mkdir -p "$app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A" \
    "$app/Contents/Frameworks/app Helper.app" "$app/Contents/Frameworks/app Helper (GPU).app" "$app/Contents/MacOS"
  echo arm64 > "$app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
  : > "$app/Contents/Frameworks/libcmux_cef_shim.dylib"
  : > "$app/Contents/MacOS/app"
  : > "$app/Contents/MacOS/app Chromium Host"
}
drop() { PATH="$TMP/bin:/usr/bin:/bin" /bin/bash "$ROOT/scripts/cmux-next/drop-cef-without-arch.sh" "$@" > /dev/null; }

# 1. x86_64 variant of an arm64-only engine: engine, helpers and host go; the app stays.
bundle "$TMP/x86"
drop "$TMP/x86/app.app" x86_64
app="$TMP/x86/app.app"
[[ ! -e "$app/Contents/Frameworks/Chromium Embedded Framework.framework" ]] || fail "the engine stayed"
[[ ! -e "$app/Contents/Frameworks/app Helper.app" ]] || fail "a helper stayed"
[[ ! -e "$app/Contents/MacOS/app Chromium Host" ]] || fail "the Chromium host stayed without its engine"
[[ -f "$app/Contents/MacOS/app" ]] || fail "the app's own executable was removed"

# 2. arm64 variant: everything stays.
bundle "$TMP/arm"
drop "$TMP/arm/app.app" arm64
[[ -f "$TMP/arm/app.app/Contents/MacOS/app Chromium Host" ]] || fail "the Chromium host was removed from a variant the engine supports"

echo "drop-cef-without-arch tests: ok"
