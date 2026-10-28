#!/usr/bin/env bash
# embed-cef.sh puts the Chromium host into every build (Release since
# p01-process-088): it builds it with build-chromium-host.sh (not with the shim)
# against the shim build and its artifact, and puts it at
# Contents/MacOS/<Product> Chromium Host (the app is Chromium's main bundle, so
# the helpers' sandbox reaches the framework); it removes the earlier
# Frameworks/<Product> Chromium Host.app; the same build's remote shim goes to
# Frameworks/libcmux_cef_shim_remote.dylib. A host that does not build leaves
# the build without the host (a warning), unless
# CMUX_NEXT_REQUIRE_CHROMIUM_HOST=1. Chromium's crash_reporter.cfg (Crashpad,
# local dumps only, p01-process task 226) goes into Contents/Resources with the
# host, only in Debug and bench builds (the ones that can start it). Every
# build step is a stand-in (no network, no compiler, no signing).
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
  "$ROOT/scripts/cmux-next/bundle-ublock.sh" "$ROOT/scripts/cmux-next/lipo-dsym.sh" \
  "$ROOT/scripts/cmux-next/chromium-host-crash-reporter.cfg" "$scripts/"
printf '{"chromium": "1.0", "debug_symbols": "Chromium Embedded Framework.dSYM.tar.xz"}\n' > "$scripts/cef-manifest.json"
dist="$TMP/dist"
mkdir -p "$dist/Chromium Embedded Framework.framework/Libraries" "$dist/Chromium Embedded Framework.framework/Resources"
: > "$dist/Chromium Embedded Framework.framework/Chromium Embedded Framework"
# The artifact's dSYM archive (tar reads it whatever its compression).
cef_dwarf="Chromium Embedded Framework.dSYM/Contents/Resources/DWARF/Chromium Embedded Framework"
mkdir -p "$TMP/cef-dsym/$(dirname "$cef_dwarf")"
printf 'cef dwarf' > "$TMP/cef-dsym/$cef_dwarf"
tar -cf "$dist/Chromium Embedded Framework.dSYM.tar.xz" -C "$TMP/cef-dsym" "Chromium Embedded Framework.dSYM"
# A stand-in dSYM, as build-cef-shim.sh and build-chromium-host.sh write beside each binary.
dsym_stub='d() { mkdir -p "$1.dSYM/Contents/Resources/DWARF"; printf "%s" "$2" > "$1.dSYM/Contents/Resources/DWARF/$(basename "$1")"; }'
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
$dsym_stub
d "$TMP/shim/libcmux_cef_shim.dylib" shim; d "$TMP/shim/cmux-cef-helper" helper
printf shim-key > "$TMP/shim/.build-key"
echo "$TMP/shim"
STUB
cat > "$scripts/build-chromium-host.sh" <<STUB
#!/usr/bin/env bash
echo "\${CMUX_CEF_ARCH:-} \$1 \$2" >> "$TMP/host-builds"
[[ -f "$TMP/host-fails" ]] && { echo "error: stand-in host compile failed" >&2; exit 1; }
mkdir -p "$TMP/host"; printf 'host binary' > "$TMP/host/cmux-chromium-host"; chmod +x "$TMP/host/cmux-chromium-host"; printf host-key > "$TMP/host/.build-key"
printf 'remote shim' > "$TMP/host/libcmux_cef_shim_remote.dylib"
$dsym_stub
d "$TMP/host/cmux-chromium-host" host; d "$TMP/host/libcmux_cef_shim_remote.dylib" remote
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
crash_config="$TMP/build/app.app/Contents/Resources/crash_reporter.cfg"

# 1. Debug: the host, built from the arm64 shim build, in Contents/MacOS; the earlier host app is removed.
mkdir -p "$old_host_app/Contents/MacOS"
embed Debug
[[ -f "$host_app" ]] || fail "a Debug embed has no Chromium host"
[[ ! -e "$old_host_app" ]] || fail "a Debug embed keeps the earlier Frameworks/... Chromium Host.app"
[[ "$(cat "$TMP/host-builds")" == "arm64 $dist $TMP/shim" ]] || fail "the host was not built once against the arm64 artifact and shim build: $(cat "$TMP/host-builds")"
[[ "$(cat "$host_app")" == "host binary" ]] || fail "the host is not the host build"
[[ "$(cat "$remote_shim")" == "remote shim" ]] || fail "a Debug embed has not the host build's remote shim"
cmp -s "$crash_config" "$ROOT/scripts/cmux-next/chromium-host-crash-reporter.cfg" ||
  fail "a Debug embed has not chromium-host-crash-reporter.cfg as Contents/Resources/crash_reporter.cfg"
# Each embedded binary's dSYM is beside the app, outside the bundle.
kept_dsym() { cat "$TMP/build/$1.dSYM/Contents/Resources/DWARF/$1" 2>/dev/null; }
for pair in libcmux_cef_shim.dylib=shim cmux-cef-helper=helper cmux-chromium-host=host libcmux_cef_shim_remote.dylib=remote; do
  [[ "$(kept_dsym "${pair%%=*}")" == "${pair#*=}" ]] || fail "a Debug embed keeps no dSYM for ${pair%%=*}: $(ls "$TMP/build")"
done
[[ ! -e "$TMP/CEF-dSYMs" ]] || fail "a Debug embed unpacked Chromium's dSYM"

# 2. Release (and so RC and NIGHTLY) on a fresh bundle: the
# host and its remote shim, as in Debug, for sign-cef.sh to sign as nested code.
rm -rf "$TMP/build/app.app" "$TMP/derived" "$TMP/host-builds"
embed Release
[[ "$(cat "$TMP/host-builds")" == "arm64 $dist $TMP/shim" ]] || fail "a Release embed did not build the host: $(cat "$TMP/host-builds" 2>/dev/null)"
[[ "$(cat "$host_app")" == "host binary" ]] || fail "a Release embed has no Chromium host"
[[ "$(cat "$remote_shim")" == "remote shim" ]] || fail "a Release embed has not the host build's remote shim"
# Chromium's crash_reporter.cfg stays out: Release never starts the host, and in-process Chromium would read it.
[[ ! -e "$crash_config" ]] || fail "a Release embed has Chromium's crash_reporter.cfg"
# Every shipped binary's dSYM stays, the host's too; Chromium's is unpacked beside the products.
for pair in libcmux_cef_shim.dylib=shim cmux-cef-helper=helper cmux-chromium-host=host libcmux_cef_shim_remote.dylib=remote; do
  [[ "$(kept_dsym "${pair%%=*}")" == "${pair#*=}" ]] || fail "a Release embed keeps no dSYM for ${pair%%=*}: $(ls "$TMP/build")"
done
[[ "$(cat "$TMP/CEF-dSYMs/arm64/$cef_dwarf" 2>/dev/null)" == "cef dwarf" ]] ||
  fail "a Release embed did not keep Chromium's dSYM: $(cat "$TMP/embed-Release.log")"
# A second Release build reuses the unpacked dSYM (the archive is not read again).
cp "$dist/Chromium Embedded Framework.dSYM.tar.xz" "$TMP/cef-dsym.tar"
printf 'not a tar' > "$dist/Chromium Embedded Framework.dSYM.tar.xz"
embed Release
[[ "$(cat "$TMP/CEF-dSYMs/arm64/$cef_dwarf" 2>/dev/null)" == "cef dwarf" ]] ||
  fail "a Release embed read the dSYM archive again instead of the unpacked one: $(cat "$TMP/embed-Release.log")"
mv "$TMP/cef-dsym.tar" "$dist/Chromium Embedded Framework.dSYM.tar.xz"
[[ -d "$TMP/build/app.app/Contents/Frameworks/app Helper.app" ]] || fail "a Release embed lost the base helper"
# A bench build (Release with -DCMUX_BENCH_HOOKS) can run the host, so it carries the cfg; a Release after it drops it.
embed Release 'OTHER_SWIFT_FLAGS=-DDEBUG_UNRELATED -DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS'
cmp -s "$crash_config" "$ROOT/scripts/cmux-next/chromium-host-crash-reporter.cfg" ||
  fail "a bench embed has not chromium-host-crash-reporter.cfg as Contents/Resources/crash_reporter.cfg"
embed Release 'OTHER_SWIFT_FLAGS=-DCMUX_BENCH_HOOKS_OFF'
[[ ! -e "$crash_config" ]] || fail "a Release embed whose flags only look like the bench flag keeps crash_reporter.cfg"

# 2b. A Release host that does not build: the Release still builds, with a warning and no host.
: > "$TMP/host-fails"
embed Release
[[ ! -e "$host_app" ]] || fail "a Release embed whose host did not build keeps a host"
[[ ! -e "$remote_shim" ]] || fail "a Release embed whose host did not build keeps the remote shim"
[[ ! -e "$crash_config" ]] || fail "a Release embed whose host did not build keeps Chromium's crash_reporter.cfg"
grep -q "warning: the Chromium host app did not build" "$TMP/embed-Release.log" || fail "no warning for a Release host that did not build"
[[ ! -e "$TMP/build/cmux-chromium-host.dSYM" && ! -e "$TMP/build/libcmux_cef_shim_remote.dylib.dSYM" ]] ||
  fail "a Release embed keeps the dSYMs of a host it does not ship"
rm -f "$TMP/host-fails" "$TMP/host-builds"

# 3. Debug with a host that does not build: the build still succeeds, says so,
# and carries no host app (none left from step 1 either).
embed Debug
[[ -f "$host_app" ]] || fail "a Debug embed has no Chromium host before the failing host"
: > "$TMP/host-fails"
embed Debug
[[ ! -e "$host_app" ]] || fail "a Debug embed whose host did not build keeps a host app"
[[ ! -e "$remote_shim" ]] || fail "a Debug embed whose host did not build keeps the remote shim"
[[ ! -e "$crash_config" ]] || fail "a Debug embed whose host did not build keeps Chromium's crash_reporter.cfg"
grep -q "warning: the Chromium host app did not build" "$TMP/embed-Debug.log" || fail "no warning for a host that did not build"
[[ -d "$TMP/build/app.app/Contents/Frameworks/app Helper.app" ]] || fail "a Debug embed whose host did not build lost the base helper"

# 4. CMUX_NEXT_SKIP_CEF=1 removes the whole CEF payload, the host with it.
rm -f "$TMP/host-fails"
embed Debug
[[ -f "$host_app" ]] || fail "a Debug embed has no Chromium host before the skip"
embed Debug CMUX_NEXT_SKIP_CEF=1
[[ ! -e "$host_app" ]] || fail "a CMUX_NEXT_SKIP_CEF=1 embed keeps the Chromium host"
[[ ! -e "$remote_shim" ]] || fail "a CMUX_NEXT_SKIP_CEF=1 embed keeps the remote shim"
[[ ! -e "$crash_config" ]] || fail "a CMUX_NEXT_SKIP_CEF=1 embed keeps Chromium's crash_reporter.cfg"
[[ -z "$(ls -d "$TMP/build/"*.dSYM 2>/dev/null)" ]] || fail "a CMUX_NEXT_SKIP_CEF=1 embed keeps dSYMs of binaries it removed"
[[ ! -e "$TMP/CEF-dSYMs" ]] || fail "a CMUX_NEXT_SKIP_CEF=1 embed keeps Chromium's dSYM"
: > "$TMP/host-fails"

# 5. The same failing host with CMUX_NEXT_REQUIRE_CHROMIUM_HOST=1: the build fails.
if run_embed Debug CMUX_NEXT_REQUIRE_CHROMIUM_HOST=1; then
  fail "CMUX_NEXT_REQUIRE_CHROMIUM_HOST=1 let a Debug embed pass without the host"
fi
grep -q "error: the Chromium host app did not build" "$TMP/embed-Debug.log" || fail "no error for a required host that did not build"

echo "embed-chromium-host tests: ok"
