#!/usr/bin/env bash
# Regression test for additional universal release assets.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/release.yml"
HELPER_SCRIPT="$ROOT_DIR/scripts/build-sign-upload.sh"

if ! awk '
  /^      - name: Build universal app \(Release\)/ { in_build=1; next }
  in_build && /^      - name:/ { in_build=0 }
  in_build && /-destination '\''generic\/platform=macOS'\''/ { saw_destination=1 }
  in_build && /ARCHS="arm64 x86_64"/ { saw_archs=1 }
  in_build && /ONLY_ACTIVE_ARCH=NO/ { saw_only_active_arch=1 }
  END { exit !(saw_destination && saw_archs && saw_only_active_arch) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: release workflow must build a separate universal app with explicit macOS universal ARCHS"
  exit 1
fi

if ! awk '
  /^      - name: Prepare universal app metadata/ { in_prepare=1; next }
  in_prepare && /^      - name:/ { in_prepare=0 }
  in_prepare && /Delete :SUPublicEDKey/ { saw_public_key_delete=1 }
  in_prepare && /Delete :SUFeedURL/ { saw_feed_delete=1 }
  END { exit !(saw_public_key_delete && saw_feed_delete) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: universal release app must disable Sparkle so the fallback download does not auto-update onto the Apple Silicon feed"
  exit 1
fi

if ! grep -Fq './scripts/sparkle_generate_appcast.sh cmux-macos.dmg "$GITHUB_REF_NAME" appcast.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: release appcast must continue to point at the default Apple Silicon DMG"
  exit 1
fi

if ! awk '
  /^      - name: Upload release asset/ { in_upload=1; next }
  in_upload && /^      - name:/ { in_upload=0 }
  in_upload && /^[[:space:]]+cmux-macos\.dmg$/ { saw_arm=1 }
  in_upload && /^[[:space:]]+cmux-macos-universal\.dmg$/ { saw_universal=1 }
  in_upload && /^[[:space:]]+appcast\.xml$/ { saw_appcast=1 }
  END { exit !(saw_arm && saw_universal && saw_appcast) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: release upload must include both Apple Silicon and universal DMGs plus appcast.xml"
  exit 1
fi

if ! grep -Fq 'cmux-macos-universal.dmg' "$HELPER_SCRIPT"; then
  echo "FAIL: manual release helper must also manage the universal DMG asset"
  exit 1
fi

if ! grep -Fq './scripts/sparkle_generate_appcast.sh cmux-macos.dmg "$TAG" appcast.xml' "$HELPER_SCRIPT"; then
  echo "FAIL: manual release helper must keep appcast generation on the default Apple Silicon DMG"
  exit 1
fi

echo "PASS: release packaging keeps the Apple Silicon default and adds a universal fallback asset"
