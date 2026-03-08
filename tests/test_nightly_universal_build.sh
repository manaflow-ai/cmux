#!/usr/bin/env bash
# Regression test for dual nightly macOS tracks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

if ! awk '
  /^      - name: Build Apple Silicon app \(Release\)/ { in_arm=1; next }
  /^      - name: Build universal app \(Release\)/ { in_universal=1; next }
  in_arm && /^      - name:/ { in_arm=0 }
  in_universal && /^      - name:/ { in_universal=0 }
  in_arm && /-destination '\''platform=macOS,arch=arm64'\''/ { saw_arm_destination=1 }
  in_arm && /ARCHS="arm64"/ { saw_arm_archs=1 }
  in_arm && /ONLY_ACTIVE_ARCH=YES/ { saw_arm_only_active_arch=1 }
  in_universal && /-destination '\''generic\/platform=macOS'\''/ { saw_universal_destination=1 }
  in_universal && /ARCHS="arm64 x86_64"/ { saw_universal_archs=1 }
  in_universal && /ONLY_ACTIVE_ARCH=NO/ { saw_universal_only_active_arch=1 }
  END {
    exit !(saw_arm_destination && saw_arm_archs && saw_arm_only_active_arch && saw_universal_destination && saw_universal_archs && saw_universal_only_active_arch)
  }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must force Apple Silicon nightly to arm64-only and universal nightly to both slices"
  exit 1
fi

if ! awk '
  /^      - name: Verify nightly binary architectures/ { in_verify=1; next }
  in_verify && /^      - name:/ { in_verify=0 }
  in_verify && /lipo -archs "\$ARM_APP_BINARY"/ { saw_arm_app=1 }
  in_verify && /lipo -archs "\$ARM_CLI_BINARY"/ { saw_arm_cli=1 }
  in_verify && /lipo -archs "\$APP_BINARY"/ { saw_app=1 }
  in_verify && /lipo -archs "\$CLI_BINARY"/ { saw_cli=1 }
  in_verify && /\[\[ "\$ARM_APP_ARCHS" == "arm64" \]\]/ { saw_arm_app_assert=1 }
  in_verify && /\[\[ "\$ARM_CLI_ARCHS" == "arm64" \]\]/ { saw_arm_cli_assert=1 }
  END { exit !(saw_arm_app && saw_arm_cli && saw_app && saw_cli && saw_arm_app_assert && saw_arm_cli_assert) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must verify arm-only and universal slices with lipo"
  exit 1
fi

if ! grep -Fq 'com.cmuxterm.app.nightly.universal' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must set a distinct .universal bundle ID"
  exit 1
fi

if ! grep -Fq 'https://github.com/manaflow-ai/cmux/releases/download/nightly/appcast-universal.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must publish a separate universal appcast feed"
  exit 1
fi

if ! grep -Fq './scripts/sparkle_generate_appcast.sh "$NIGHTLY_UNIVERSAL_DMG_IMMUTABLE" nightly appcast-universal.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must generate a separate universal appcast"
  exit 1
fi

if ! grep -Fq "core.setOutput('should_publish', isMainRef ? 'true' : 'false');" "$WORKFLOW_FILE"; then
  echo "FAIL: nightly decide step must expose should_publish based on whether the ref is main"
  exit 1
fi

if ! awk '
  /^      - name: Upload branch nightly artifacts/ { in_upload=1; next }
  in_upload && /^      - name:/ { in_upload=0 }
  in_upload && /if: needs\.decide\.outputs\.should_publish != '\''true'\''/ { saw_if=1 }
  in_upload && /uses: actions\/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4/ { saw_upload=1 }
  in_upload && /cmux-nightly-macos\*\.dmg/ { saw_arm_artifacts=1 }
  in_upload && /cmux-nightly-universal-macos\*\.dmg/ { saw_universal_artifacts=1 }
  in_upload && /appcast-universal\.xml/ { saw_universal_appcast=1 }
  END { exit !(saw_if && saw_upload && saw_arm_artifacts && saw_universal_artifacts && saw_universal_appcast) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: non-main nightly runs must upload both nightly variants and both appcasts"
  exit 1
fi

if ! awk '
  /^      - name: Move nightly tag to built commit/ { in_move=1; next }
  in_move && /^      - name:/ { in_move=0 }
  in_move && /if: needs\.decide\.outputs\.should_publish == '\''true'\''/ { saw_move_if=1 }
  END { exit !saw_move_if }
' "$WORKFLOW_FILE"; then
  echo "FAIL: moving the nightly tag must be gated to main nightly publishes"
  exit 1
fi

if ! awk '
  /^      - name: Publish nightly release assets/ { in_publish=1; next }
  in_publish && /^      - name:/ { in_publish=0 }
  in_publish && /if: needs\.decide\.outputs\.should_publish == '\''true'\''/ { saw_publish_if=1 }
  in_publish && /cmux-nightly-universal-macos-\$\{\{ github\.run_id \}\}\*\.dmg/ { saw_universal_immutable=1 }
  in_publish && /cmux-nightly-universal-macos\.dmg/ { saw_universal_stable=1 }
  in_publish && /appcast-universal\.xml/ { saw_universal_appcast=1 }
  END { exit !(saw_publish_if && saw_universal_immutable && saw_universal_stable && saw_universal_appcast) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: main nightly publish must include the universal assets and appcast"
  exit 1
fi

echo "PASS: nightly workflow keeps separate Apple Silicon and universal nightly tracks"
