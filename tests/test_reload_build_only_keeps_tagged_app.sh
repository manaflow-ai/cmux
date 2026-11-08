#!/usr/bin/env bash
# Regression test: --build-only promises to leave the running tagged app alone, but
# reload.sh clears stale xcodebuild outputs before every build, and that cleanup
# removed the tagged bundle, which is the one a running tagged app executes from.
# A normal reload puts it back; build-only never did.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELOAD="$ROOT_DIR/scripts/reload.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Run the real functions, not a copy of them.
functions="$(awk '
  /^remove_app_bundle_output\(\) \{$/ || /^cleanup_incomplete_xcodebuild_outputs\(\) \{$/ { on = 1 }
  on { print }
  on && /^\}$/ { on = 0 }
' "$RELOAD")"
[[ "$functions" == *"cleanup_incomplete_xcodebuild_outputs()"* ]] \
  || fail "could not find cleanup_incomplete_xcodebuild_outputs in reload.sh"
eval "$functions"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

seed() {
  BUILD_PRODUCTS_DEBUG_DIR="$TMP_DIR/$1/Build/Products/Debug"
  XCODEBUILD_SOURCE_APP_PATH="$BUILD_PRODUCTS_DEBUG_DIR/cmux DEV.app"
  XCODEBUILD_TAG_APP_PATH="$BUILD_PRODUCTS_DEBUG_DIR/cmux DEV probe.app"
  TAG_APP_STAGING_PATH="$BUILD_PRODUCTS_DEBUG_DIR/.cmux DEV probe.reload-1.app"
  XCODEBUILD_CLEANED_OUTPUTS=0
  mkdir -p "$XCODEBUILD_SOURCE_APP_PATH" "$XCODEBUILD_TAG_APP_PATH/Contents/MacOS" "$TAG_APP_STAGING_PATH"
  printf 'running\n' > "$XCODEBUILD_TAG_APP_PATH/Contents/MacOS/cmux DEV"
}

# Build-only: the tagged bundle survives; this run's own outputs are still cleared.
seed build-only
BUILD_ONLY=1
cleanup_incomplete_xcodebuild_outputs
[[ -f "$XCODEBUILD_TAG_APP_PATH/Contents/MacOS/cmux DEV" ]] \
  || fail "--build-only removed the tagged app bundle a running app executes from"
[[ ! -e "$XCODEBUILD_SOURCE_APP_PATH" ]] || fail "--build-only kept a stale xcodebuild source app"
[[ ! -e "$TAG_APP_STAGING_PATH" ]] || fail "--build-only kept a stale staging app"
echo "PASS: --build-only keeps the tagged app bundle and still clears its own outputs"

# A normal reload is unchanged: it replaces the tagged bundle, so stale ones still go.
seed reload
BUILD_ONLY=0
cleanup_incomplete_xcodebuild_outputs
[[ ! -e "$XCODEBUILD_TAG_APP_PATH" ]] || fail "a normal reload no longer clears the stale tagged app"
[[ ! -e "$XCODEBUILD_SOURCE_APP_PATH" && ! -e "$TAG_APP_STAGING_PATH" ]] \
  || fail "a normal reload no longer clears stale xcodebuild outputs"
echo "PASS: a normal reload still clears the stale tagged app"
# A build-only base-name override aliases the xcodebuild source bundle to the
# running tagged bundle, so it must be rejected before any build or cleanup.
set +e
collision_output="$(CMUX_DEV_BACKEND_MODE=local "$RELOAD" --tag probe --name "cmux DEV" --build-only 2>&1)"
collision_status=$?
set -e
[[ "$collision_status" -ne 0 ]] || fail "--build-only accepted a source/tag bundle name collision"
[[ "$collision_output" == *"--build-only cannot use --name 'cmux DEV'"* ]] \
  || fail "collision refusal did not explain the protected bundle name"
echo "PASS: --build-only rejects a name override that aliases the running tagged bundle"

# A normal tagged reload must stop the previous process before replacing the
# final app path. Otherwise a process that is still starting can lose its
# SwiftPM resource bundle and trap in Bundle.module during diagnostics setup.
terminate_line="$(grep -n 'TAG_PROCESS_PATTERN=' "$RELOAD" | head -n1 | cut -d: -f1)"
replace_line="$(grep -n 'rm -rf "\$TAG_APP_FINAL_PATH"' "$RELOAD" | head -n1 | cut -d: -f1)"
[[ -n "$terminate_line" && -n "$replace_line" && "$terminate_line" -lt "$replace_line" ]] \
  || fail "normal tagged reload can replace the app bundle before terminating the prior process"
echo "PASS: normal tagged reload terminates before replacing the final app bundle"
