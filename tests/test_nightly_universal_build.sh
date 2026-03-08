#!/usr/bin/env bash
# Regression test for nightly universal macOS builds.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

if ! awk '
  /^      - name: Build app \(Release\)/ { in_build=1; next }
  in_build && /^      - name:/ { in_build=0 }
  in_build && /-destination '\''generic\/platform=macOS'\''/ { saw_destination=1 }
  in_build && /ARCHS="arm64 x86_64"/ { saw_archs=1 }
  in_build && /ONLY_ACTIVE_ARCH=NO/ { saw_only_active_arch=1 }
  END { exit !(saw_destination && saw_archs && saw_only_active_arch) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly build step must target generic macOS with explicit universal ARCHS"
  exit 1
fi

if ! awk '
  /^      - name: Verify universal binaries/ { in_verify=1; next }
  in_verify && /^      - name:/ { in_verify=0 }
  in_verify && /lipo -archs "\$APP_BINARY"/ { saw_app=1 }
  in_verify && /lipo -archs "\$CLI_BINARY"/ { saw_cli=1 }
  END { exit !(saw_app && saw_cli) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must verify both app and CLI universal slices with lipo"
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
  END { exit !(saw_if && saw_upload) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: non-main nightly runs must upload artifacts instead of publishing the official nightly release"
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
  END { exit !saw_publish_if }
' "$WORKFLOW_FILE"; then
  echo "FAIL: publishing nightly release assets must be gated to main nightly publishes"
  exit 1
fi

echo "PASS: nightly workflow keeps universal builds and safe branch dispatch behavior"
