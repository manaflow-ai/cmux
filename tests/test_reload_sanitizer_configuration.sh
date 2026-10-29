#!/usr/bin/env bash
# reload.sh --config asan|tsan|ubsan: the Release configuration with
# that sanitizer, symbols kept, under its own tag (the config is the suffix, so the bundle id ends in
# .asan/.tsan/.ubsan). check-no-bench-hooks.sh, which the release, nightly and build-sign-upload
# pipelines run on the app they ship, refuses a sanitizer app, and --expect-sanitizer requires the
# runtime linked and embedded.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOAD="$ROOT_DIR/scripts/reload.sh"
CHECK="$ROOT_DIR/scripts/cmux-next/check-no-bench-hooks.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
TAG="sanitizer-probe-$$"
lock_file() { python3 -c 'import os, sys, tempfile; print(os.path.join(tempfile.gettempdir(), "cmux-reload-tags-%d" % os.getuid(), sys.argv[1] + ".lock"))' "$1"; }
cleanup() {
  rm -rf "$TMP_DIR"
  for suffix in "" -asan -tsan -ubsan; do
    rm -f "/tmp/cmux-reload-${TAG}${suffix}.log" "$(lock_file "${TAG}${suffix}")"
  done
}
trap cleanup EXIT

# A scratch checkout whose build steps are stubs; the xcodebuild stub records its arguments, then fails.
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
printf '%s\n' "$@" > "$STUB_ARGS"
exit 3
STUB
chmod +x "$TMP_DIR/bin/xcodebuild"

OUTPUT="" STATUS=0
run_reload() {
  rm -f "$ARGS"
  set +e
  OUTPUT="$(cd "$CHECKOUT" && env \
    -u CMUX_TUI_CLIENT_LOCAL -u CMUX_TUI_CLIENT_MANIFEST_URL -u CMUX_SOURCE_PACKAGES_DIR \
    -u CMUX_DERIVED_DATA -u CMUX_RELOAD_TAG_LOCK_OWNER -u CMUX_DEV_BACKEND_URL \
    -u CMUX_SWIFT_FRONTEND_WORKAROUND -u CMUX_SWIFT_DISABLE_GLOBAL_ISEL \
    PATH="$TMP_DIR/bin:$PATH" STUB_ARGS="$ARGS" CMUX_SKIP_CMUX_TUI_CLIENT=1 \
    CMUX_DEV_BACKEND_MODE=local \
    CMUX_NEXT_TUI_BIN="$TMP_DIR/cmux-tui" CMUX_NEXT_ACPMUX_BIN="$TMP_DIR/acpmux" \
    "$RELOAD" "$@" 2>&1)"
  STATUS=$?
  set -e
}
arg_after() { awk -v key="$1" 'found { print; exit } $0 == key { found = 1 }' "$ARGS"; }

for kind in asan tsan ubsan; do
  case "$kind" in
    asan) flag=-enableAddressSanitizer ;;
    tsan) flag=-enableThreadSanitizer ;;
    ubsan) flag=-enableUndefinedBehaviorSanitizer ;;
  esac
  run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config "$kind"
  [[ -f "$ARGS" ]] || fail "--config $kind never reached xcodebuild: $OUTPUT"
  [[ "$(arg_after -configuration)" == Release ]] || fail "--config $kind built '$(arg_after -configuration)', not Release"
  [[ "$(arg_after "$flag")" == YES ]] || fail "--config $kind did not pass $flag YES: $(tr '\n' ' ' < "$ARGS")"
  for other in -enableAddressSanitizer -enableThreadSanitizer -enableUndefinedBehaviorSanitizer; do
    [[ "$other" == "$flag" ]] || ! grep -qx -- "$other" "$ARGS" || fail "--config $kind also passed $other"
  done
  grep -qx "PRODUCT_BUNDLE_IDENTIFIER=com.cmuxterm.app.debug.${TAG//-/.}.${kind}" "$ARGS" \
    || fail "--config $kind bundle id is not the tag's with .$kind: $(grep PRODUCT_BUNDLE_IDENTIFIER "$ARGS")"
  for setting in DEBUG_INFORMATION_FORMAT=dwarf-with-dsym COPY_PHASE_STRIP=NO STRIP_INSTALLED_PRODUCT=NO DEPLOYMENT_POSTPROCESSING=NO; do
    grep -qx "$setting" "$ARGS" || fail "--config $kind does not keep symbols ($setting missing)"
  done
  ! grep -q -- '-DCMUX_BENCH_HOOKS' "$ARGS" || fail "--config $kind compiled the bench hooks in"
  grep -qx 'CODE_SIGN_ENTITLEMENTS=' "$ARGS" || fail "--config $kind kept the Release entitlements"
done
echo "PASS: --config asan|tsan|ubsan build Release with that sanitizer only, symbols kept, under <tag>-<config>"

run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config release
grep -q -- 'Sanitizer' "$ARGS" && fail "--config release passed a sanitizer: $(grep Sanitizer "$ARGS")"
grep -qx "PRODUCT_BUNDLE_IDENTIFIER=com.cmuxterm.app.debug.${TAG//-/.}" "$ARGS" || fail "--config release changed the tag"
echo "PASS: --config release passes no sanitizer and keeps the tag"

run_reload --tag "$TAG" --build-only --config msan
(( STATUS != 0 )) && [[ "$OUTPUT" == *"debug, release, bench, bench-checks, profile, asan, tsan or ubsan"* ]] \
  || fail "an unknown config was not refused with the config list: $OUTPUT"
run_reload --tag "$TAG" --build-only --config asan --bundle-id com.cmuxterm.app.debug.other
(( STATUS != 0 )) && [[ "$OUTPUT" == *"drop --bundle-id and --name"* ]] || fail "--config asan accepted --bundle-id: $OUTPUT"
run_reload --tag "$TAG" --build-only --config tsan --swift-frontend-workaround
(( STATUS != 0 )) && [[ "$OUTPUT" == *"keeps debug symbols"* ]] || fail "--config tsan accepted the symbol-dropping workaround: $OUTPUT"
echo "PASS: the config list is debug|release|bench|bench-checks|profile|asan|tsan|ubsan; a sanitizer config refuses a custom id or no symbols"

# check-no-bench-hooks.sh on fake bundles.
make_app() {
  local app="$1" body="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
  python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleExecutable": "cmux"}, open(sys.argv[1], "wb"))' "$app/Contents/Info.plist"
  printf '%s' "$body" > "$app/Contents/MacOS/cmux"
}
plain="$TMP_DIR/plain.app" asan="$TMP_DIR/asan.app" unembedded="$TMP_DIR/unembedded.app" bench="$TMP_DIR/bench.app"
make_app "$plain" "plain executable"
make_app "$asan" "@rpath/libclang_rt.asan_osx_dynamic.dylib"
: > "$asan/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"
make_app "$unembedded" "@rpath/libclang_rt.tsan_osx_dynamic.dylib"
make_app "$bench" "CMUX_BENCH_HOOKS""_BUILD"

"$CHECK" "$plain" >/dev/null || fail "a plain app was refused"
! "$CHECK" "$asan" >/dev/null 2>&1 || fail "the shipped check let an ASan app through"
! "$CHECK" "$unembedded" >/dev/null 2>&1 || fail "the shipped check let an app linked to TSan through"
! "$CHECK" "$bench" >/dev/null 2>&1 || fail "the shipped check let a bench app through"
"$CHECK" --expect-sanitizer asan "$asan" >/dev/null || fail "--expect-sanitizer asan refused an ASan app"
! "$CHECK" --expect-sanitizer tsan "$asan" >/dev/null 2>&1 || fail "--expect-sanitizer tsan accepted an ASan app"
! "$CHECK" --expect-sanitizer tsan "$unembedded" >/dev/null 2>&1 || fail "--expect-sanitizer accepted an app without the runtime embedded"
! "$CHECK" --expect-sanitizer asan "$plain" >/dev/null 2>&1 || fail "--expect-sanitizer accepted a plain app"
"$CHECK" --expect "$bench" >/dev/null || fail "--expect refused a bench app"
! "$CHECK" --expect "$asan" >/dev/null 2>&1 || fail "--expect accepted an ASan app"
echo "PASS: check-no-bench-hooks.sh refuses sanitizer apps for shipping and checks --expect-sanitizer"
