#!/usr/bin/env bash
# embed-cef.sh puts the Chromium host into every build (Release since
# p01-process-088): it builds it with build-chromium-host.sh (not with the shim)
# against the shim build and its artifact, and puts it at
# Contents/MacOS/<Product> Chromium Host (the app is Chromium's main bundle, so
# the helpers' sandbox reaches the framework); it removes the earlier
# Frameworks/<Product> Chromium Host.app; the same build's remote shim goes to
# Frameworks/libcmux_cef_shim_remote.dylib. A host that does not build leaves
# the build without the host (a warning), unless
# CMUX_NEXT_REQUIRE_CHROMIUM_HOST=1. Every build step is a stand-in (no
# network, no compiler, no signing).
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
printf shim-key > "$TMP/shim/.build-key"
echo "$TMP/shim"
STUB
cat > "$scripts/build-chromium-host.sh" <<STUB
#!/usr/bin/env bash
echo "\${CMUX_CEF_ARCH:-} \$1 \$2" >> "$TMP/host-builds"
[[ -f "$TMP/host-fails" ]] && { echo "error: stand-in host compile failed" >&2; exit 1; }
mkdir -p "$TMP/host"; printf 'host binary' > "$TMP/host/cmux-chromium-host"; chmod +x "$TMP/host/cmux-chromium-host"; printf host-key > "$TMP/host/.build-key"
printf 'remote shim' > "$TMP/host/libcmux_cef_shim_remote.dylib"
echo "$TMP/host"
STUB
chmod +x "$scripts/"*.sh

run_embed() { # <configuration> [VAR=value...]: embed-cef.sh's status, output in $TMP/embed-<configuration>.log
  local configuration="$1"
  shift
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" ARCHS=arm64 TARGET_BUILD_DIR="$TMP/build" WRAPPER_NAME=app.app \
    PRODUCT_NAME=app PRODUCT_BUNDLE_IDENTIFIER=test.app DERIVED_FILE_DIR="$TMP/derived" CMUX_NEXT_SKIP_UBLOCK=1 \
    CONFIGURATION="$configuration" "$@" /bin/bash "$scripts/embed-cef.sh" > "$TMP/embed-$configuration.log" 2>&1
}
embed() { # <configuration> [VAR=value...]
  run_embed "$@" || fail "embed-cef.sh failed for $1: $(cat "$TMP/embed-$1.log")"
}
host_app="$TMP/build/app.app/Contents/MacOS/app Chromium Host"
remote_shim="$TMP/build/app.app/Contents/Frameworks/libcmux_cef_shim_remote.dylib"
old_host_app="$TMP/build/app.app/Contents/Frameworks/app Chromium Host.app"

# 1. Debug: the host, built from the arm64 shim build, in Contents/MacOS; the earlier host app is removed.
mkdir -p "$old_host_app/Contents/MacOS"
embed Debug
[[ -f "$host_app" ]] || fail "a Debug embed has no Chromium host"
[[ ! -e "$old_host_app" ]] || fail "a Debug embed keeps the earlier Frameworks/... Chromium Host.app"
[[ "$(cat "$TMP/host-builds")" == "arm64 $dist $TMP/shim" ]] || fail "the host was not built once against the arm64 artifact and shim build: $(cat "$TMP/host-builds")"
[[ "$(cat "$host_app")" == "host binary" ]] || fail "the host is not the host build"
[[ "$(cat "$remote_shim")" == "remote shim" ]] || fail "a Debug embed has not the host build's remote shim"

# 2. Release (and so RC and NIGHTLY, p01-process-088) on a fresh bundle: the
# host and its remote shim, as in Debug, for sign-cef.sh to sign as nested code.
rm -rf "$TMP/build/app.app" "$TMP/derived" "$TMP/host-builds"
embed Release
[[ "$(cat "$TMP/host-builds")" == "arm64 $dist $TMP/shim" ]] || fail "a Release embed did not build the host: $(cat "$TMP/host-builds" 2>/dev/null)"
[[ "$(cat "$host_app")" == "host binary" ]] || fail "a Release embed has no Chromium host"
[[ "$(cat "$remote_shim")" == "remote shim" ]] || fail "a Release embed has not the host build's remote shim"
[[ -d "$TMP/build/app.app/Contents/Frameworks/app Helper.app" ]] || fail "a Release embed lost the base helper"

# 2b. A Release host that does not build: the Release still builds, with a warning and no host.
: > "$TMP/host-fails"
embed Release
[[ ! -e "$host_app" ]] || fail "a Release embed whose host did not build keeps a host"
[[ ! -e "$remote_shim" ]] || fail "a Release embed whose host did not build keeps the remote shim"
grep -q "warning: the Chromium host app did not build" "$TMP/embed-Release.log" || fail "no warning for a Release host that did not build"
rm -f "$TMP/host-fails" "$TMP/host-builds"

# 3. Debug with a host that does not build: the build still succeeds, says so,
# and carries no host app (none left from step 1 either).
embed Debug
[[ -f "$host_app" ]] || fail "a Debug embed has no Chromium host before the failing host"
: > "$TMP/host-fails"
embed Debug
[[ ! -e "$host_app" ]] || fail "a Debug embed whose host did not build keeps a host app"
[[ ! -e "$remote_shim" ]] || fail "a Debug embed whose host did not build keeps the remote shim"
grep -q "warning: the Chromium host app did not build" "$TMP/embed-Debug.log" || fail "no warning for a host that did not build"
[[ -d "$TMP/build/app.app/Contents/Frameworks/app Helper.app" ]] || fail "a Debug embed whose host did not build lost the base helper"

# 4. CMUX_NEXT_SKIP_CEF=1 removes the whole CEF payload, the host with it.
rm -f "$TMP/host-fails"
embed Debug
[[ -f "$host_app" ]] || fail "a Debug embed has no Chromium host before the skip"
embed Debug CMUX_NEXT_SKIP_CEF=1
[[ ! -e "$host_app" ]] || fail "a CMUX_NEXT_SKIP_CEF=1 embed keeps the Chromium host"
[[ ! -e "$remote_shim" ]] || fail "a CMUX_NEXT_SKIP_CEF=1 embed keeps the remote shim"
: > "$TMP/host-fails"

# 5. The same failing host with CMUX_NEXT_REQUIRE_CHROMIUM_HOST=1: the build fails.
if run_embed Debug CMUX_NEXT_REQUIRE_CHROMIUM_HOST=1; then
  fail "CMUX_NEXT_REQUIRE_CHROMIUM_HOST=1 let a Debug embed pass without the host"
fi
grep -q "error: the Chromium host app did not build" "$TMP/embed-Debug.log" || fail "no error for a required host that did not build"

echo "embed-chromium-host tests: ok"
