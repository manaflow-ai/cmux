#!/usr/bin/env bash
# Regression test: reload.sh only built the Debug configuration, so every fleet
# dogfood build (cmux-ci build cmux, with or without --production) was -Onone with
# DEBUG defined, and perf impressions came from unoptimized code. --release builds
# the Release configuration of the same tagged app: the same tagged bundle id, the
# checkout's own cmux-tui (tree mode, not Release's pinned default), no Release
# entitlements on the ad hoc signed app, and products read from Build/Products/Release.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOAD="$ROOT_DIR/scripts/reload.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
TAG="release-probe-$$"
LOCK_FILE="$(python3 -c 'import os, sys, tempfile; print(os.path.join(tempfile.gettempdir(), "cmux-reload-tags-%d" % os.getuid(), sys.argv[1] + ".lock"))' "$TAG")"
cleanup() {
  rm -rf "$TMP_DIR"
  rm -f "/tmp/cmux-reload-${TAG}.log" "$LOCK_FILE"
}
trap cleanup EXIT

# A scratch checkout whose build steps are stubs. The xcodebuild stub records its
# arguments and the cmux-tui mode it was given, then fails, so no run goes past it.
CHECKOUT="$TMP_DIR/checkout"
ARGS="$TMP_DIR/xcodebuild-args"
mkdir -p "$CHECKOUT/scripts/lib" "$TMP_DIR/bin"
ln -s "$ROOT_DIR/scripts/lib/dev-backend-origin.sh" "$CHECKOUT/scripts/lib/dev-backend-origin.sh"
for stub in dev-backend.sh ensure-ghosttykit.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CHECKOUT/scripts/$stub"
  chmod +x "$CHECKOUT/scripts/$stub"
done
cat > "$TMP_DIR/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == -version ]] && { echo "Xcode 26.6"; exit 0; }
{ printf 'tui-mode=%s\n' "${CMUX_NEXT_TUI_MODE-unset}"; printf 'acpmux-archs=%s\n' "${CMUX_NEXT_ACPMUX_ARCHS-unset}"; printf '%s\n' "$@"; } > "$STUB_ARGS"
exit 3
STUB
chmod +x "$TMP_DIR/bin/xcodebuild"

OUTPUT=""
RUN_ENV=()
run_reload() {
  rm -f "$ARGS"
  set +e
  OUTPUT="$(cd "$CHECKOUT" && env \
    -u CMUX_TUI_CLIENT_LOCAL -u CMUX_TUI_CLIENT_MANIFEST_URL -u CMUX_SOURCE_PACKAGES_DIR \
    -u CMUX_DERIVED_DATA -u CMUX_RELOAD_TAG_LOCK_OWNER -u CMUX_DEV_BACKEND_URL \
    -u CMUX_CI_STEP_CLASS -u CMUX_RELOAD_NATIVE_ARCH -u CMUX_NEXT_ACPMUX_ARCHS -u CMUX_NEXT_OPTCHAT_CHIEF_ARCHS \
    -u CMUX_NEXT_MOBILE_HOST_ARCHS \
    PATH="$TMP_DIR/bin:$PATH" STUB_ARGS="$ARGS" CMUX_SKIP_CMUX_TUI_CLIENT=1 \
    CMUX_DEV_BACKEND_MODE=local CMUX_NEXT_TUI_MODE=pin \
    CMUX_NEXT_TUI_BIN="$TMP_DIR/cmux-tui" CMUX_NEXT_ACPMUX_BIN="$TMP_DIR/acpmux" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$RELOAD" "$@" 2>&1)"
  STATUS=$?
  set -e
}
arg_after() { awk -v key="$1" 'found { print; exit } $0 == key { found = 1 }' "$ARGS"; }

run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --release
[[ -f "$ARGS" ]] || fail "--release never reached xcodebuild: $OUTPUT"
[[ "$(arg_after -configuration)" == Release ]] \
  || fail "--release built configuration '$(arg_after -configuration)', not Release"
grep -qx "PRODUCT_BUNDLE_IDENTIFIER=com.cmuxterm.app.debug.${TAG//-/.}" "$ARGS" \
  || fail "--release did not keep the tagged debug bundle id: $(grep PRODUCT_BUNDLE_IDENTIFIER "$ARGS")"
grep -qx 'CODE_SIGN_ENTITLEMENTS=' "$ARGS" \
  || fail "--release kept the Release entitlements on an ad hoc signed tagged app"
grep -qx 'tui-mode=tree' "$ARGS" \
  || fail "--release did not force the checkout's own cmux-tui: $(head -n 1 "$ARGS")"
echo "PASS: --release builds the tagged app in Release with tree-mode cmux-tui and no Release entitlements"

run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd"
[[ -f "$ARGS" ]] || fail "the default reload never reached xcodebuild: $OUTPUT"
[[ "$(arg_after -configuration)" == Debug ]] || fail "the default reload no longer builds Debug"
grep -qx 'tui-mode=pin' "$ARGS" || fail "the default reload overrode the caller's CMUX_NEXT_TUI_MODE"
! grep -qx 'CODE_SIGN_ENTITLEMENTS=' "$ARGS" || fail "the default reload changed entitlements"
echo "PASS: without --release the reload still builds Debug and leaves the cmux-tui mode alone"

# The product directory and source app name follow the configuration: Release's
# product is cmux.app, which the tag step renames to the tagged app.
products="$(awk '/^[[:space:]]*BUILD_PRODUCTS_DEBUG_DIR=.*Build\/Products/ { print; exit }' "$RELOAD")"
[[ "$products" == *'$BUILD_CONFIGURATION'* || "$products" == *'${BUILD_CONFIGURATION}'* ]] \
  || fail "reload.sh still reads products from a fixed directory: $products"
echo "PASS: products are read from the built configuration's directory"

# A fleet measurement step (CMUX_CI_STEP_CLASS=exclusive) builds the app only to run it on this Mac, so it
# builds this Mac's architecture alone (chat-open.sh step b128e339 timed out in a universal Release build).
host_arch="$(uname -m)"; [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] && host_arch=arm64
RUN_ENV=(CMUX_CI_STEP_CLASS=exclusive)
run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config bench
[[ -f "$ARGS" ]] || fail "the measurement reload never reached xcodebuild: $OUTPUT"
grep -qx "ARCHS=$host_arch" "$ARGS" || fail "a measurement step's Release build is not ARCHS=$host_arch: $(grep ARCH "$ARGS" || true)"
grep -qx 'ONLY_ACTIVE_ARCH=YES' "$ARGS" || fail "a measurement step's Release build does not set ONLY_ACTIVE_ARCH=YES"
grep -qx "acpmux-archs=$host_arch" "$ARGS" || fail "a measurement step bundles a universal acpmux: $(grep acpmux-archs "$ARGS")"
RUN_ENV=(CMUX_CI_STEP_CLASS=exclusive CMUX_RELOAD_NATIVE_ARCH=0)
run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config bench
! grep -q '^ARCHS=' "$ARGS" || fail "CMUX_RELOAD_NATIVE_ARCH=0 did not keep the universal build"
grep -qx 'acpmux-archs=arm64 x86_64' "$ARGS" || fail "CMUX_RELOAD_NATIVE_ARCH=0 did not keep a universal acpmux"
RUN_ENV=()
run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --release
! grep -q '^ARCHS=' "$ARGS" || fail "a Release reload outside a measurement step is no longer universal"
! grep -qx 'ONLY_ACTIVE_ARCH=YES' "$ARGS" || fail "a Release reload outside a measurement step set ONLY_ACTIVE_ARCH=YES"
run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --release --native-arch
grep -qx "ARCHS=$host_arch" "$ARGS" || fail "--native-arch did not build ARCHS=$host_arch"
grep -qx "acpmux-archs=$host_arch" "$ARGS" || fail "--native-arch bundles a universal acpmux"
RUN_ENV=(CMUX_NEXT_ACPMUX_ARCHS="arm64 x86_64")
run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --release --native-arch
grep -qx 'acpmux-archs=arm64 x86_64' "$ARGS" || fail "--native-arch overrode an explicit CMUX_NEXT_ACPMUX_ARCHS"
RUN_ENV=()
echo "PASS: a measurement step (or --native-arch) builds this Mac's architecture only; other Release reloads stay universal"
