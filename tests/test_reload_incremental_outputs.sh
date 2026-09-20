#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/reload-incremental.sh"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-reload-incremental.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

for STEP in cmuxd ghostty cua tui; do
  INPUT="$TEMP_DIR/${STEP}.input"
  OUTPUT="$TEMP_DIR/${STEP}.output"
  RECEIPT="$TEMP_DIR/${STEP}.receipt"
  printf 'initial\n' > "$INPUT"
  printf 'built\n' > "$OUTPUT"
  INPUT_DIGEST="$(reload_incremental_tree_digest "$INPUT")"
  reload_incremental_record "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"

  ! reload_incremental_needs_update "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"
  printf 'changed\n' >> "$INPUT"
  CHANGED_DIGEST="$(reload_incremental_tree_digest "$INPUT")"
  reload_incremental_needs_update "$RECEIPT" "$CHANGED_DIGEST" "$OUTPUT"
  rm "$OUTPUT"
  reload_incremental_needs_update "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"
  printf 'recreated\n' > "$OUTPUT"
  reload_incremental_record "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"
  printf 'corrupted\n' > "$OUTPUT"
  reload_incremental_needs_update "$RECEIPT" "$INPUT_DIGEST" "$OUTPUT"
done

echo "reload incremental output checks passed"

APP="$TEMP_DIR/cmux DEV sample.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
printf 'plist\n' > "$APP/Contents/Info.plist"
printf 'executable\n' > "$APP/Contents/MacOS/cmux DEV"
printf 'helper\n' > "$APP/Contents/Resources/bin/cmuxd"
APP_RECEIPT="$TEMP_DIR/sample-tag/tagged-app.receipt"
APP_INPUT="$(reload_incremental_manifest_digest 'tag=sample\napp=cmux DEV sample\nbundle=com.cmuxterm.app.debug.sample')"
reload_incremental_record "$APP_RECEIPT" "$APP_INPUT" "$APP"
! reload_incremental_needs_update "$APP_RECEIPT" "$APP_INPUT" "$APP"
printf 'corrupted\n' > "$APP/Contents/Info.plist"
reload_incremental_needs_update "$APP_RECEIPT" "$APP_INPUT" "$APP"

# An unsigned bundle is hashed as a whole tree, so a changed executable or helper is seen.
printf 'plist\n' > "$APP/Contents/Info.plist"
reload_incremental_record "$APP_RECEIPT" "$APP_INPUT" "$APP"
! reload_incremental_needs_update "$APP_RECEIPT" "$APP_INPUT" "$APP"
printf 'rebuilt executable\n' > "$APP/Contents/MacOS/cmux DEV"
reload_incremental_needs_update "$APP_RECEIPT" "$APP_INPUT" "$APP"
printf 'executable\n' > "$APP/Contents/MacOS/cmux DEV"
! reload_incremental_needs_update "$APP_RECEIPT" "$APP_INPUT" "$APP"
printf 'rebuilt helper\n' > "$APP/Contents/Resources/bin/cmuxd"
reload_incremental_needs_update "$APP_RECEIPT" "$APP_INPUT" "$APP"

# A signed bundle is fingerprinted from its seal plus its executables: a changed
# resource shows up in the seal, a changed executable is hashed directly.
SIGNED="$TEMP_DIR/signed.app"
mkdir -p "$SIGNED/Contents/MacOS" "$SIGNED/Contents/Resources/bin" "$SIGNED/Contents/_CodeSignature"
printf 'plist\n' > "$SIGNED/Contents/Info.plist"
printf 'executable\n' > "$SIGNED/Contents/MacOS/cmux DEV"
printf 'helper\n' > "$SIGNED/Contents/Resources/bin/cmuxd"
printf 'seal-1\n' > "$SIGNED/Contents/_CodeSignature/CodeResources"
BUILT_ONE="$(reload_incremental_app_digest "$SIGNED")"
[[ "$BUILT_ONE" == "$(reload_incremental_app_digest "$SIGNED")" ]]
printf 'seal-2\n' > "$SIGNED/Contents/_CodeSignature/CodeResources"
[[ "$BUILT_ONE" != "$(reload_incremental_app_digest "$SIGNED")" ]]
printf 'seal-1\n' > "$SIGNED/Contents/_CodeSignature/CodeResources"
[[ "$BUILT_ONE" == "$(reload_incremental_app_digest "$SIGNED")" ]]
printf 'relinked\n' > "$SIGNED/Contents/MacOS/cmux DEV"
[[ "$BUILT_ONE" != "$(reload_incremental_app_digest "$SIGNED")" ]]

# reload.sh must fingerprint the built app, not uncommitted diffs: a committed change
# or a branch switch leaves `git diff` empty while xcodebuild produces a different app.
grep -q 'built_app=$(reload_incremental_app_digest "$APP_PATH")' "$ROOT/scripts/reload.sh"
! grep -q 'git diff --binary -- Sources' "$ROOT/scripts/reload.sh"
[[ "$(reload_incremental_manifest_digest 'tag=sample\napp=cmux DEV sample')" == "$(reload_incremental_manifest_digest 'tag=sample\napp=cmux DEV sample')" ]]
