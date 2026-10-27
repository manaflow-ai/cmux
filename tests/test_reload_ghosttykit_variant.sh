#!/usr/bin/env bash
# reload.sh and the libghostty variant (chrome-parity p10-stability-165): a sanitizer config
# (--config asan|tsan|ubsan, p10-stability-012) links the ReleaseSafe lab libghostty
# (ensure-ghosttykit.sh --variant safe; CMUX_GHOSTTYKIT_VARIANT=safe with CMUX_SANITIZER_CONFIG for
# Packages/Shared/CmuxGhosttyKit/Package.swift); every other config links the pinned ReleaseFast one
# and refuses CMUX_GHOSTTYKIT_VARIANT=safe. Runs anywhere (Linux included): xcodebuild and
# ensure-ghosttykit.sh are stubs that record their arguments and environment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOAD="$ROOT_DIR/scripts/reload.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
TAG="ghosttykit-variant-probe-$$"
lock_file() { python3 -c 'import os, sys, tempfile; print(os.path.join(tempfile.gettempdir(), "cmux-reload-tags-%d" % os.getuid(), sys.argv[1] + ".lock"))' "$1"; }
cleanup() {
  rm -rf "$TMP_DIR"
  for suffix in "" -asan -tsan -ubsan; do
    rm -f "/tmp/cmux-reload-${TAG}${suffix}.log" "$(lock_file "${TAG}${suffix}")"
  done
}
trap cleanup EXIT

CHECKOUT="$TMP_DIR/checkout"
XCODE_ENV="$TMP_DIR/xcodebuild-env"
ENSURE_CALLS="$TMP_DIR/ensure-calls"
mkdir -p "$CHECKOUT/scripts/lib" "$TMP_DIR/bin"
ln -s "$ROOT_DIR/scripts/lib/dev-backend-origin.sh" "$CHECKOUT/scripts/lib/dev-backend-origin.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CHECKOUT/scripts/dev-backend.sh"
cat > "$CHECKOUT/scripts/ensure-ghosttykit.sh" <<'STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$*" >> "$STUB_ENSURE_CALLS"
STUB
chmod +x "$CHECKOUT/scripts/dev-backend.sh" "$CHECKOUT/scripts/ensure-ghosttykit.sh"
cat > "$TMP_DIR/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == -version ]] && { echo "Xcode 26.6"; exit 0; }
printf 'CMUX_GHOSTTYKIT_VARIANT=%s\nCMUX_SANITIZER_CONFIG=%s\n' \
  "${CMUX_GHOSTTYKIT_VARIANT-<unset>}" "${CMUX_SANITIZER_CONFIG-<unset>}" > "$STUB_XCODE_ENV"
exit 3
STUB
chmod +x "$TMP_DIR/bin/xcodebuild"

OUTPUT="" STATUS=0
run_reload() {
  local variant="$1"
  shift
  rm -f "$XCODE_ENV" "$ENSURE_CALLS"
  set +e
  OUTPUT="$(cd "$CHECKOUT" && env \
    -u CMUX_TUI_CLIENT_LOCAL -u CMUX_TUI_CLIENT_MANIFEST_URL -u CMUX_SOURCE_PACKAGES_DIR \
    -u CMUX_DERIVED_DATA -u CMUX_RELOAD_TAG_LOCK_OWNER -u CMUX_DEV_BACKEND_URL \
    -u CMUX_SWIFT_FRONTEND_WORKAROUND -u CMUX_SWIFT_DISABLE_GLOBAL_ISEL -u CMUX_GHOSTTYKIT_PREPROVISIONED \
    PATH="$TMP_DIR/bin:$PATH" STUB_XCODE_ENV="$XCODE_ENV" STUB_ENSURE_CALLS="$ENSURE_CALLS" \
    CMUX_SKIP_CMUX_TUI_CLIENT=1 CMUX_DEV_BACKEND_MODE=local CMUX_NEXT_TUI_MODE=pin \
    CMUX_NEXT_TUI_BIN="$TMP_DIR/cmux-tui" CMUX_NEXT_ACPMUX_BIN="$TMP_DIR/acpmux" \
    CMUX_GHOSTTYKIT_VARIANT="$variant" CMUX_SANITIZER_CONFIG=asan \
    "$RELOAD" "$@" 2>&1)"
  STATUS=$?
  set -e
}

refused() { (( STATUS != 0 )) && [[ "$OUTPUT" == *"$1"* ]]; }

# Every config a shipped build uses links ReleaseFast, clears a stray sanitizer config and refuses safe.
for config in debug release bench; do
  run_reload "" --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config "$config"
  [[ -f "$XCODE_ENV" ]] || fail "--config $config never reached xcodebuild: $OUTPUT"
  grep -qx 'CMUX_GHOSTTYKIT_VARIANT=fast' "$XCODE_ENV" || fail "--config $config: $(cat "$XCODE_ENV")"
  grep -qx 'CMUX_SANITIZER_CONFIG=<unset>' "$XCODE_ENV" || fail "--config $config kept a sanitizer config: $(cat "$XCODE_ENV")"
  [[ "$(cat "$ENSURE_CALLS")" == "[]" ]] || fail "--config $config ran ensure-ghosttykit.sh as $(tr '\n' ' ' < "$ENSURE_CALLS")"

  run_reload safe --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config "$config"
  refused "refuses CMUX_GHOSTTYKIT_VARIANT=safe" \
    || fail "--config $config accepted CMUX_GHOSTTYKIT_VARIANT=safe: $OUTPUT"
  [[ ! -f "$XCODE_ENV" && ! -f "$ENSURE_CALLS" ]] || fail "--config $config built before refusing the safe variant"
done
run_reload bogus --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config release
refused "refuses CMUX_GHOSTTYKIT_VARIANT=bogus" \
  || fail "an unknown variant was not refused: $OUTPUT"
echo "PASS: debug, release and bench link the ReleaseFast libghostty and refuse the safe variant"

# The sanitizer configs come with p10-stability-012; until reload.sh has them there is nothing to select.
if ! grep -q 'asan | tsan | ubsan)' "$RELOAD"; then
  echo "SKIP: reload.sh has no --config asan|tsan|ubsan yet (p10-stability-012)"
  exit 0
fi
for kind in asan tsan ubsan; do
  for variant in "" safe; do
    run_reload "$variant" --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config "$kind"
    [[ -f "$XCODE_ENV" ]] || fail "--config $kind never reached xcodebuild: $OUTPUT"
    grep -qx 'CMUX_GHOSTTYKIT_VARIANT=safe' "$XCODE_ENV" || fail "--config $kind: $(cat "$XCODE_ENV")"
    grep -qx "CMUX_SANITIZER_CONFIG=$kind" "$XCODE_ENV" || fail "--config $kind: $(cat "$XCODE_ENV")"
    grep -qx '\[--variant safe\]' "$ENSURE_CALLS" || fail "--config $kind did not ensure the safe variant: $(cat "$ENSURE_CALLS")"
  done
  run_reload fast --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config "$kind"
  refused "refuses CMUX_GHOSTTYKIT_VARIANT=fast" \
    || fail "--config $kind accepted the ReleaseFast variant: $OUTPUT"
done
echo "PASS: asan, tsan and ubsan link the ReleaseSafe libghostty under their sanitizer config"
