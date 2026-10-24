#!/usr/bin/env bash
# embed-cef.sh puts the Chromium host app (prototype) into Debug builds only:
# a Debug embed builds it with build-chromium-host.sh (not with the shim) and
# bundles "<Product> Chromium Host.app" with its own bundle id; a Release embed
# never builds it and removes one left by an earlier Debug build, so Release,
# RC and NIGHTLY bundles carry no host app. Every build step is a stand-in
# (no network, no compiler, no signing).
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change the
# host's embed or build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/embed-chromium-host-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

scripts="$TMP/scripts"
mkdir -p "$scripts" "$TMP/build" "$TMP/cache" "$TMP/bin"
cp "$ROOT/scripts/cmux-next/embed-cef.sh" "$ROOT/scripts/cmux-next/cef-locale-allowlist.sh" \
  "$ROOT/scripts/cmux-next/bundle-ublock.sh" "$scripts/"
printf '{"chromium": "1.0"}\n' > "$scripts/cef-manifest.json"
dist="$TMP/dist"
mkdir -p "$dist/Chromium Embedded Framework.framework/Libraries" "$dist/Chromium Embedded Framework.framework/Resources"
: > "$dist/Chromium Embedded Framework.framework/Chromium Embedded Framework"
if ! command -v ditto >/dev/null; then
  printf '#!/usr/bin/env bash\nmkdir -p "$(dirname "$2")"; cp -R "$1" "$2"\n' > "$TMP/bin/ditto"
  chmod +x "$TMP/bin/ditto"
fi
for stub in install-cef-credits.sh install-cef-license.sh sign-cef.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$scripts/$stub"
done
printf '#!/usr/bin/env bash\necho "%s"\n' "$dist" > "$scripts/ensure-cef.sh"
printf '#!/usr/bin/env bash\necho "%s"\n' "$TMP/cache" > "$scripts/cef-cache-root.sh"
# The shim build carries no host binary.
cat > "$scripts/build-cef-shim.sh" <<STUB
#!/usr/bin/env bash
mkdir -p "$TMP/shim"
: > "$TMP/shim/libcmux_cef_shim.dylib"; : > "$TMP/shim/cmux-cef-helper"; : > "$TMP/shim/libcef_dll_wrapper.a"
printf -- '-arch\narm64\n' > "$TMP/shim/compile-flags"; printf shim-key > "$TMP/shim/.build-key"
echo "$TMP/shim"
STUB
cat > "$scripts/build-chromium-host.sh" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$TMP/host-builds"
mkdir -p "$TMP/host"; printf 'host binary' > "$TMP/host/cmux-chromium-host"; printf host-key > "$TMP/host/.build-key"
echo "$TMP/host"
STUB
chmod +x "$scripts/"*.sh

embed() { # <configuration>
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" ARCHS=arm64 TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    PRODUCT_NAME=app PRODUCT_BUNDLE_IDENTIFIER=test.app DERIVED_FILE_DIR="$TMP/derived" CMUX_NEXT_SKIP_UBLOCK=1 \
    CONFIGURATION="$1" /bin/bash "$scripts/embed-cef.sh" > "$TMP/embed-$1.log" 2>&1 \
    || fail "embed-cef.sh failed for $1: $(cat "$TMP/embed-$1.log")"
}
plist_value() { # <plist> <key>
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
  else
    /usr/bin/python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]])' "$1" "$2"
  fi
}
host_app="$TMP/build/app.app/Contents/Frameworks/app Chromium Host.app"

# 1. Debug: the host app, built from the arm64 shim build, with its own bundle id.
embed Debug
[[ -d "$host_app" ]] || fail "a Debug embed has no Chromium host app"
[[ "$(cat "$TMP/host-builds")" == "$TMP/shim" ]] || fail "the host was not built once against the shim build: $(cat "$TMP/host-builds")"
[[ "$(cat "$host_app/Contents/MacOS/app Chromium Host")" == "host binary" ]] || fail "the host app does not carry the host build"
[[ "$(plist_value "$host_app/Contents/Info.plist" CFBundleIdentifier)" == test.app.chromium-host ]] || fail "host bundle id"
[[ "$(plist_value "$host_app/Contents/Info.plist" CFBundleExecutable)" == "app Chromium Host" ]] || fail "host executable name"

# 2. Release on the same bundle: no host build, and the Debug host app is gone.
rm -f "$TMP/host-builds"
embed Release
[[ ! -e "$host_app" ]] || fail "a Release embed keeps a Chromium host app"
[[ ! -e "$TMP/host-builds" ]] || fail "a Release embed built the Chromium host"
[[ -d "$TMP/build/app.app/Contents/Frameworks/app Helper.app" ]] || fail "a Release embed lost the base helper"

echo "embed-chromium-host tests: ok"
