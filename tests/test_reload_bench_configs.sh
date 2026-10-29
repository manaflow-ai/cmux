#!/usr/bin/env bash
# Regression test: `reload.sh --config bench` added -DCMUX_BLOCKING_CHECKS, so every
# latency, frame, launch, idle and memory bench paid the blocking detector's bookkeeping. bench is now
# Release + -DCMUX_BENCH_HOOKS only; bench-checks adds -DCMUX_BLOCKING_CHECKS for the blocking-sites story.
# Runs anywhere (Linux included): xcodebuild is a stub that records its arguments and fails.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOAD="$ROOT_DIR/scripts/reload.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
TAG="bench-config-probe-$$"
DOGFOOD_TAG="chrome-parity-probe-$$"
lock_file() { python3 -c 'import os, sys, tempfile; print(os.path.join(tempfile.gettempdir(), "cmux-reload-tags-%d" % os.getuid(), sys.argv[1] + ".lock"))' "$1"; }
LOCK_FILE="$(lock_file "$TAG")"
DOGFOOD_LOCK_FILE="$(lock_file "$DOGFOOD_TAG")"
cleanup() {
  rm -rf "$TMP_DIR"
  rm -f "/tmp/cmux-reload-${TAG}.log" "$LOCK_FILE" "/tmp/cmux-reload-${DOGFOOD_TAG}.log" "$DOGFOOD_LOCK_FILE"
}
trap cleanup EXIT

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

OUTPUT=""
STATUS=0
run_reload() {
  rm -f "$ARGS"
  set +e
  OUTPUT="$(cd "$CHECKOUT" && env \
    -u CMUX_TUI_CLIENT_LOCAL -u CMUX_TUI_CLIENT_MANIFEST_URL -u CMUX_SOURCE_PACKAGES_DIR \
    -u CMUX_DERIVED_DATA -u CMUX_RELOAD_TAG_LOCK_OWNER -u CMUX_DEV_BACKEND_URL \
    PATH="$TMP_DIR/bin:$PATH" STUB_ARGS="$ARGS" CMUX_SKIP_CMUX_TUI_CLIENT=1 \
    CMUX_DEV_BACKEND_MODE=local CMUX_NEXT_TUI_MODE=pin \
    CMUX_NEXT_TUI_BIN="$TMP_DIR/cmux-tui" CMUX_NEXT_ACPMUX_BIN="$TMP_DIR/acpmux" \
    "$RELOAD" "$@" 2>&1)"
  STATUS=$?
  set -e
}
arg_after() { awk -v key="$1" 'found { print; exit } $0 == key { found = 1 }' "$ARGS"; }
swift_flags() { grep '^OTHER_SWIFT_FLAGS=' "$ARGS" || true; }

run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config bench
[[ -f "$ARGS" ]] || fail "--config bench never reached xcodebuild: $OUTPUT"
[[ "$(arg_after -configuration)" == Release ]] || fail "--config bench built '$(arg_after -configuration)', not Release"
[[ "$(swift_flags)" == *-DCMUX_BENCH_HOOKS* ]] || fail "--config bench lost -DCMUX_BENCH_HOOKS: $(swift_flags)"
[[ "$(swift_flags)" != *-DCMUX_BLOCKING_CHECKS* ]] || fail "--config bench still compiles the blocking detector: $(swift_flags)"
[[ "$(swift_flags)" != *-DDEBUG* ]] || fail "--config bench defines DEBUG: $(swift_flags)"
grep -qx 'CMUX_BENCH_HOOKS_RELOAD=1' "$ARGS" || fail "--config bench does not tell the embed phases it is a bench build"
echo "PASS: bench is Release + CMUX_BENCH_HOOKS without CMUX_BLOCKING_CHECKS"

run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config=bench-checks
[[ -f "$ARGS" ]] || fail "--config bench-checks never reached xcodebuild: $OUTPUT"
[[ "$(arg_after -configuration)" == Release ]] || fail "--config bench-checks built '$(arg_after -configuration)', not Release"
[[ "$(swift_flags)" == *-DCMUX_BENCH_HOOKS* ]] || fail "--config bench-checks lost -DCMUX_BENCH_HOOKS: $(swift_flags)"
[[ "$(swift_flags)" == *-DCMUX_BLOCKING_CHECKS* ]] || fail "--config bench-checks has no -DCMUX_BLOCKING_CHECKS: $(swift_flags)"
echo "PASS: bench-checks is bench + CMUX_BLOCKING_CHECKS"

for config in release debug; do
  run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config "$config"
  [[ -f "$ARGS" ]] || fail "--config $config never reached xcodebuild: $OUTPUT"
  [[ "$(swift_flags)" != *-DCMUX_BENCH_HOOKS* && "$(swift_flags)" != *-DCMUX_BLOCKING_CHECKS* ]] \
    || fail "--config $config compiles bench flags: $(swift_flags)"
  ! grep -q 'CMUX_BENCH_HOOKS_RELOAD' "$ARGS" || fail "--config $config marks itself a bench build"
done
echo "PASS: release and debug carry neither bench flag"

# --release after --config bench-checks means release: the last configuration flag wins.
run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config bench-checks --release
[[ -f "$ARGS" ]] || fail "--config bench-checks --release never reached xcodebuild: $OUTPUT"
[[ "$(swift_flags)" != *-DCMUX_BENCH_HOOKS* && "$(swift_flags)" != *-DCMUX_BLOCKING_CHECKS* ]] \
  || fail "--release after --config bench-checks kept bench flags: $(swift_flags)"
echo "PASS: a later --release clears the bench flags"

# A dogfood tag (Resources/build/cmux-next.dogfood.conf release_bench_tags) builds bench on --release, the one
# configuration flag the fleet recipe passes; `--config release` stays plain Release (first-seconds-lag.md step 4).
run_reload --tag "$DOGFOOD_TAG" --build-only --derived-data "$TMP_DIR/dd" --release
[[ -f "$ARGS" ]] || fail "--release of a dogfood tag never reached xcodebuild: $OUTPUT"
[[ "$(arg_after -configuration)" == Release ]] || fail "--release of a dogfood tag built '$(arg_after -configuration)', not Release"
[[ "$(swift_flags)" == *-DCMUX_BENCH_HOOKS* ]] || fail "--release of a dogfood tag has no -DCMUX_BENCH_HOOKS: $(swift_flags)"
[[ "$(swift_flags)" != *-DCMUX_BLOCKING_CHECKS* && "$(swift_flags)" != *-DDEBUG* ]] \
  || fail "--release of a dogfood tag compiles the blocking detector or DEBUG: $(swift_flags)"
run_reload --tag "$DOGFOOD_TAG" --build-only --derived-data "$TMP_DIR/dd" --config release
[[ -f "$ARGS" && "$(swift_flags)" != *-DCMUX_BENCH_HOOKS* ]] || fail "--config release of a dogfood tag compiles bench flags: $(swift_flags)"
echo "PASS: --release of a dogfood tag is bench; --config release stays Release"

run_reload --tag "$TAG" --build-only --derived-data "$TMP_DIR/dd" --config bench-check
[[ "$STATUS" -ne 0 && "$OUTPUT" == *"debug, release, bench, bench-checks, profile, asan, tsan or ubsan"* ]] \
  || fail "an unknown config was not refused with the config list: $OUTPUT"
echo "PASS: an unknown config is refused"
