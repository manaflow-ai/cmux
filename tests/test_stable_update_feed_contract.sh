#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_FEED="https://files.cmux.com/stable/appcast.xml"
LEGACY_FEED="https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml"

"$ROOT_DIR/tests/test_release_version_contract.sh"
bash "$ROOT_DIR/tests/test_build_sign_upload_contract.sh"
node --test "$ROOT_DIR/scripts/release_asset_guard.test.js"
python3 "$ROOT_DIR/tests/test_classify_stable_release.py"
python3 "$ROOT_DIR/tests/test_release_appcast_asset_validation.py"

python3 - "$ROOT_DIR/Resources/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    plist = plistlib.load(handle)
if plist.get("SUAllowsAutomaticUpdates") is not False:
    raise SystemExit("FAIL: Sparkle automatic installs bypass the fresh latest-resolution path")
PY

FILES=(
  "$ROOT_DIR/Resources/Info.plist"
  "$ROOT_DIR/.github/workflows/release.yml"
  "$ROOT_DIR/Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateFeedResolver.swift"
)

for file in "${FILES[@]}"; do
  if ! rg -Fq "$EXPECTED_FEED" "$file"; then
    echo "FAIL: $file does not use the atomic stable appcast" >&2
    exit 1
  fi
  if rg -Fq "$LEGACY_FEED" "$file"; then
    echo "FAIL: $file still uses the redirect-based stable appcast" >&2
    exit 1
  fi
done

MANUAL_RELEASE="$ROOT_DIR/scripts/build-sign-upload.sh"
if ! rg -Fq 'gh workflow run release.yml' "$MANUAL_RELEASE" \
  || ! rg -Fq 'operation=publish-existing' "$MANUAL_RELEASE" \
  || rg -Fq 'upload-r2-object.py' "$MANUAL_RELEASE" \
  || rg -Fq 'gh release edit' "$MANUAL_RELEASE"; then
  echo "FAIL: the manual release path bypasses serialized workflow publication" >&2
  exit 1
fi

if ! rg -Fq -- '--repair-appcast' "$MANUAL_RELEASE" \
  || ! rg -Fq -- '--field operation=publish-existing' "$MANUAL_RELEASE" \
  || ! rg -Fq -- '--field release_tag="$TAG"' "$MANUAL_RELEASE" \
  || ! rg -Fq -- '--ref "$WORKFLOW_REF"' "$MANUAL_RELEASE" \
  || rg -Fq -- '--ref "$TAG"' "$MANUAL_RELEASE"; then
  echo "FAIL: manual appcast repair does not use serialized workflow publication" >&2
  exit 1
fi

RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
if ! rg -Fq 'gh release download \' "$RELEASE_WORKFLOW" \
  || ! rg -Fq -- '--output "$APPCAST_PATH"' "$RELEASE_WORKFLOW"; then
  echo "FAIL: release retries cannot repair a missing canonical appcast from immutable assets" >&2
  exit 1
fi

if ! rg -Fq 'release_tag:' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'CHECKOUT_REF="$RELEASE_TAG"' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'name: Resolve and validate artifact release tag' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'RELEASE_TAG="v$(printf' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'ref: ${{ needs.release-preflight.outputs.checkout_ref }}' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'path: .release-tools' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'RELEASE_TOOL_ROOT="./.release-tools"' "$RELEASE_WORKFLOW" \
  || ! rg -Fq '$OPERATION requires release_tag=v<major>.<minor>.<patch>' "$RELEASE_WORKFLOW"; then
  echo "FAIL: default-branch publication does not validate and checkout an explicit release tag" >&2
  exit 1
fi

if ! rg -Fq 'name: Finalize complete draft release' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'steps.guard_release_assets.outputs.finalize_draft' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'gh release edit "$RELEASE_TAG" --draft=false --latest=false' "$RELEASE_WORKFLOW"; then
  echo "FAIL: complete draft release retries cannot reach public asset validation" >&2
  exit 1
fi

if ! rg -Fq 'group: cmux-stable-release-publication' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'make_latest: false' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'name: Classify stable release order at publication time' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'steps.publish_release_order.outputs.is_latest' "$RELEASE_WORKFLOW" \
  || ! rg -Fq "if: needs.release-preflight.outputs.should_publish == 'true' && steps.publish_release_order.outputs.is_latest == 'true'" "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'gh release edit "${{ steps.publish_release_order.outputs.latest_tag }}" --latest' "$RELEASE_WORKFLOW"; then
  echo "FAIL: GitHub latest and the canonical feed do not share one release-order decision" >&2
  exit 1
fi

UPLOAD_LINE="$(rg -n -m1 'name: Upload release asset' "$RELEASE_WORKFLOW" | cut -d: -f1)"
CLASSIFY_LINE="$(rg -n -m1 'name: Classify stable release order at publication time' "$RELEASE_WORKFLOW" | cut -d: -f1)"
if [[ -z "$UPLOAD_LINE" || -z "$CLASSIFY_LINE" || "$CLASSIFY_LINE" -le "$UPLOAD_LINE" ]]; then
  echo "FAIL: stable release order is classified before the long build instead of at publication" >&2
  exit 1
fi

if ! rg -Fq 'scripts/ci/validate_release_appcast_assets.py' "$RELEASE_WORKFLOW" \
  || ! rg -Fq '"$RELEASE_TOOL_ROOT/scripts/validate-release-version.sh"' "$RELEASE_WORKFLOW"; then
  echo "FAIL: release publication does not validate the tag and complete appcast artifact" >&2
  exit 1
fi


GUARD_LINE="$(rg -n -m1 'name: Guard immutable release assets' "$RELEASE_WORKFLOW" | cut -d: -f1)"
STRICT_LINE="$(rg -n -m1 'name: Validate Sparkle build number is monotonic' "$RELEASE_WORKFLOW" | cut -d: -f1)"
if [[ -z "$GUARD_LINE" || -z "$STRICT_LINE" || "$STRICT_LINE" -le "$GUARD_LINE" ]] \
  || ! rg -A2 -F 'name: Validate Sparkle build number is monotonic' "$RELEASE_WORKFLOW" \
    | rg -Fq "if: steps.guard_release_assets.outputs.skip_all != 'true'"; then
  echo "FAIL: canonical-feed repair must run for existing immutable releases even when R2 is unavailable" >&2
  exit 1
fi

if ! rg -Fq 'release-preflight:' "$RELEASE_WORKFLOW" \
  || ! rg -Fq "if: needs.release-preflight.outputs.skip_all != 'true'" "$RELEASE_WORKFLOW" \
  || ! rg -Fq "needs.release-preflight.outputs.skip_all == 'true'" "$RELEASE_WORKFLOW"; then
  echo "FAIL: immutable-asset retries still depend on the Ghostty helper build" >&2
  exit 1
fi

if ! rg -Fq -- '--allow-missing-current-feed' "$RELEASE_WORKFLOW" \
  || ! rg -Fq 'steps.guard_release_assets.outputs.skip_all' "$RELEASE_WORKFLOW"; then
  echo "FAIL: only an explicit immutable-asset retry may repair a missing canonical feed" >&2
  exit 1
fi

if ! rg -Fq 'operation=publish-existing' "$MANUAL_RELEASE" \
  || ! rg -Fq 'git ls-remote --exit-code origin "refs/tags/$TAG"' "$MANUAL_RELEASE" \
  || ! rg -Fq 'git show "HEAD:cmux.xcodeproj/project.pbxproj"' "$MANUAL_RELEASE" \
  || ! rg -Fq 'git diff --cached --quiet' "$MANUAL_RELEASE"; then
  echo "FAIL: manual appcast repair is coupled to the current checkout or an unverified local tag" >&2
  exit 1
fi

if ! rg -Fq 'Nightly appcast-only repair is unsupported' "$MANUAL_RELEASE"; then
  echo "FAIL: release wrapper silently treats nightly repair as a full rebuild" >&2
  exit 1
fi

HOMEBREW_WORKFLOW="$ROOT_DIR/.github/workflows/update-homebrew.yml"
if rg -Fq 'workflow_run:' "$HOMEBREW_WORKFLOW" \
  || ! rg -Fq 'group: cmux-stable-release-publication' "$HOMEBREW_WORKFLOW" \
  || ! rg -Fq -- '--json tagName,isLatest' "$HOMEBREW_WORKFLOW" \
  || ! rg -Fq 'if [[ "$TAG" != "$LATEST_TAG" ]]' "$HOMEBREW_WORKFLOW" \
  || ! rg -Fq 'name: Queue Homebrew update for the verified latest release' "$RELEASE_WORKFLOW"; then
  echo "FAIL: delayed Homebrew jobs can roll the cask back from GitHub latest" >&2
  exit 1
fi

if [[ "$(rg -c 'timeout-minutes: 40' "$RELEASE_WORKFLOW")" != "1" ]] \
  || [[ "$(rg -c 'Add :SUPublicEDKey string \$\{SPARKLE_PUBLIC_KEY\}' "$RELEASE_WORKFLOW")" != "1" ]]; then
  echo "FAIL: release workflow contains duplicated build keys or timeout settings" >&2
  exit 1
fi

NIGHTLY_WORKFLOW="$ROOT_DIR/.github/workflows/nightly.yml"
if ! rg -Fq 'name: Validate nightly appcast before publication' "$NIGHTLY_WORKFLOW" \
  || ! rg -Fq 'preserve_order: true' "$NIGHTLY_WORKFLOW"; then
  echo "FAIL: nightly appcast can publish before its full immutable artifact is validated" >&2
  exit 1
fi

GENERATOR="$ROOT_DIR/scripts/sparkle_generate_appcast.sh"
if ! rg -Fq 'archives_dir="$work_dir/archives"' "$GENERATOR" \
  || ! rg -Fq 'cp "$DMG_PATH" "$archives_dir/$(basename "$DMG_PATH")"' "$GENERATOR"; then
  echo "FAIL: appcast generation must isolate the current full DMG from prior releases" >&2
  exit 1
fi
if rg -Fq "xml.replace(" "$GENERATOR"; then
  echo "FAIL: appcast signatures must never be injected with text replacement" >&2
  exit 1
fi

echo "PASS: every shipped stable feed entrypoint uses $EXPECTED_FEED"
