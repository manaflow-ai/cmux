#!/usr/bin/env bash
# drop-cef-without-arch.sh drops the Chromium engine from a thin variant whose
# arch the framework lacks, and the Chromium host and its remote shim with it.
# Since Release bundles carry the host, an arm64-only host left
# in the x86_64 variant would fail scripts/thin-app-bundle.sh; a host without
# the arch goes alone even when the engine stays.
# lipo is a stand-in on PATH: a "Mach-O" here is a text file naming its archs.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# drop-cef-without-arch.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drop-cef-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/lipo" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -archs ]]; then cat "$2"; exit 0; fi
[[ "$2" == -verify_arch ]] && grep -qw -- "$3" "$1"
STUB
chmod +x "$TMP/bin/lipo"

bundle() { # <dir> <engine archs> <host archs>
  local app="$1/app.app" fw="$1/app.app/Contents/Frameworks"
  mkdir -p "$fw/Chromium Embedded Framework.framework/Versions/A" "$fw/app Helper.app" "$fw/app Helper (GPU).app" "$app/Contents/MacOS"
  printf '%s' "$2" > "$fw/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
  : > "$fw/libcmux_cef_shim.dylib"
  : > "$fw/libcmux_cef_shim_remote.dylib"
  printf '%s' "$3" > "$app/Contents/MacOS/app Chromium Host"
  printf 'x86_64 arm64' > "$app/Contents/MacOS/app"
}
drop() { # <dir> <arch>
  PATH="$TMP/bin:/usr/bin:/bin" /bin/bash "$ROOT/scripts/cmux-next/drop-cef-without-arch.sh" "$1/app.app" "$2" > "$1/drop.log" 2>&1 ||
    fail "drop-cef-without-arch.sh failed: $(cat "$1/drop.log")"
}

# 1. An arm64-only engine and host in the x86_64 variant: all of it goes.
mkdir "$TMP/arm-only"
bundle "$TMP/arm-only" arm64 arm64
drop "$TMP/arm-only" x86_64
for gone in "Contents/Frameworks/Chromium Embedded Framework.framework" Contents/Frameworks/libcmux_cef_shim.dylib \
  "Contents/Frameworks/app Helper.app" "Contents/Frameworks/app Helper (GPU).app" \
  "Contents/MacOS/app Chromium Host" Contents/Frameworks/libcmux_cef_shim_remote.dylib; do
  [[ ! -e "$TMP/arm-only/app.app/$gone" ]] || fail "the x86_64 variant keeps $gone"
done
[[ -f "$TMP/arm-only/app.app/Contents/MacOS/app" ]] || fail "the app's own executable was removed"

# 2. A universal engine and host: everything stays.
mkdir "$TMP/universal"
bundle "$TMP/universal" "x86_64 arm64" "x86_64 arm64"
drop "$TMP/universal" x86_64
[[ -f "$TMP/universal/app.app/Contents/MacOS/app Chromium Host" ]] || fail "a universal host was dropped"
[[ -f "$TMP/universal/app.app/Contents/Frameworks/libcmux_cef_shim_remote.dylib" ]] || fail "a universal host's remote shim was dropped"

# 3. A universal engine whose host is arm64 only: the host and its remote shim
# go with a warning, the engine stays.
mkdir "$TMP/host-arm"
bundle "$TMP/host-arm" "x86_64 arm64" arm64
drop "$TMP/host-arm" x86_64
[[ ! -e "$TMP/host-arm/app.app/Contents/MacOS/app Chromium Host" ]] || fail "an arm64-only host stays in the x86_64 variant"
[[ ! -e "$TMP/host-arm/app.app/Contents/Frameworks/libcmux_cef_shim_remote.dylib" ]] || fail "the dropped host's remote shim stays"
[[ -d "$TMP/host-arm/app.app/Contents/Frameworks/Chromium Embedded Framework.framework" ]] || fail "the engine was dropped with the host"
grep -q "No Chromium host for x86_64" "$TMP/host-arm/drop.log" || fail "no warning for the dropped host: $(cat "$TMP/host-arm/drop.log")"

# 4. The arm64 variant of the same bundle keeps everything.
mkdir "$TMP/arm-variant"
bundle "$TMP/arm-variant" "x86_64 arm64" arm64
drop "$TMP/arm-variant" arm64
[[ -f "$TMP/arm-variant/app.app/Contents/MacOS/app Chromium Host" ]] || fail "the arm64 variant lost its host"

echo "drop-cef-without-arch tests: ok"
