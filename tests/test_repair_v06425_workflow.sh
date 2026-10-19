#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/repair-v0-64-25-helper-rpaths.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

grep -Fq 'name: Repair v0.64.25 cmux-cua rpaths' "$WORKFLOW"
grep -Fq 'default: ""' "$WORKFLOW"
grep -Fq 'group: stable-appcast-publication' "$WORKFLOW"
grep -Fq 'group: stable-appcast-publication' "$RELEASE_WORKFLOW"
grep -Fq 'cancel-in-progress: false' "$WORKFLOW"
grep -Fq 'cancel-in-progress: false' "$RELEASE_WORKFLOW"
grep -Fq "if: inputs.confirmation != 'v0.64.25'" "$WORKFLOW"
if [ "$(grep -Fc "if: inputs.confirmation == 'v0.64.25'" "$WORKFLOW")" -lt 2 ]; then
  echo 'FAIL: replacement steps must require the exact v0.64.25 confirmation' >&2
  exit 1
fi

for required in \
  './scripts/strip-cmux-cua-rpaths.sh' \
  './scripts/verify-bundle-load-commands.sh' \
  'syspolicy_check distribution "$APP_PATH"' \
  './scripts/sparkle_generate_appcast.sh "$DMG_PATH" "$TARGET_TAG" "$APPCAST_PATH"' \
  'gh release upload "$TARGET_TAG" "$DMG_PATH" "$APPCAST_PATH"' \
  'scripts/ci/upload-r2-object.py'; do
  if ! grep -Fq "$required" "$WORKFLOW"; then
    echo "FAIL: repair workflow is missing required operation: $required" >&2
    exit 1
  fi
done

dry_run_line="$(grep -n 'name: Upload dry-run artifacts' "$WORKFLOW" | cut -d: -f1)"
release_replace_line="$(grep -n 'name: Replace v0.64.25 GitHub release assets' "$WORKFLOW" | cut -d: -f1)"
r2_replace_line="$(grep -n 'name: Replace stable R2 appcast when v0.64.25 is current' "$WORKFLOW" | cut -d: -f1)"
if [ -z "$dry_run_line" ] || [ -z "$release_replace_line" ] || [ -z "$r2_replace_line" ] \
  || [ "$dry_run_line" -ge "$release_replace_line" ] \
  || [ "$release_replace_line" -ge "$r2_replace_line" ]; then
  echo 'FAIL: dry-run and publication steps are out of order' >&2
  exit 1
fi

echo 'PASS: v0.64.25 repair workflow defaults to dry-run and gates publication'
