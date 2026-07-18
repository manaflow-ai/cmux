#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/nightly.yml"

build_job="$(awk '
  /^  build-nightly-app:/ { capture=1 }
  capture && /^  build-sign-notarize-nightly:/ { exit }
  capture { print }
' "$WORKFLOW")"

publish_job="$(awk '
  /^  build-sign-notarize-nightly:/ { capture=1 }
  capture { print }
' "$WORKFLOW")"

strip_line="$(grep -nF -- '- name: Strip unsigned nightly app before transfer' <<< "$build_job" | cut -d: -f1 || true)"
archive_line="$(grep -nF -- '- name: Archive unsigned nightly app' <<< "$build_job" | cut -d: -f1 || true)"
if [ -z "$strip_line" ] || [ -z "$archive_line" ] || [ "$strip_line" -ge "$archive_line" ]; then
  echo "FAIL: unsigned app must be stripped before cross-job archive transfer" >&2
  exit 1
fi
if ! grep -Fq './scripts/strip-release-bundle.sh "$products/cmux.app"' <<< "$build_job"; then
  echo "FAIL: pre-transfer strip must use the guarded release-bundle helper" >&2
  exit 1
fi
if grep -Fq -- '- name: Strip nightly release binaries' <<< "$publish_job"; then
  echo "FAIL: publishing job must not repeat stripping after transfer" >&2
  exit 1
fi

notarize_step="$(awk '
  /^      - name: Notarize app ticket through final DMG/ { capture=1; next }
  capture && /^      - name:/ { exit }
  capture { print }
' <<< "$publish_job")"

submit_count="$(grep -c 'xcrun notarytool submit' <<< "$notarize_step" || true)"
if [ "$submit_count" -ne 1 ]; then
  echo "FAIL: Nightly must make exactly one notarization submission" >&2
  exit 1
fi
for requirement in \
  'xcrun notarytool submit "$dmg_release"' \
  'xcrun stapler staple "$app_path"' \
  'xcrun stapler validate "$app_path"' \
  'spctl -a -vv --type execute "$app_path"' \
  'xcrun stapler staple "$dmg_release"' \
  'xcrun stapler validate "$dmg_release"' \
  'hdiutil attach "$dmg_release"' \
  'spctl -a -vv --type execute "$mounted_app"' \
  'smoke-launch-macos-app.sh "$mounted_app"'; do
  if ! grep -Fq "$requirement" <<< "$notarize_step"; then
    echo "FAIL: single-submission notarization missing delivered-artifact check: $requirement" >&2
    exit 1
  fi
done
if grep -Fq 'notarytool submit "$zip_submit"' <<< "$notarize_step"; then
  echo "FAIL: redundant app ZIP notarization submission remains" >&2
  exit 1
fi

echo "PASS: Nightly applies proven speedups without dropping artifact checks"
