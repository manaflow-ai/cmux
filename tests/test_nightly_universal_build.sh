#!/usr/bin/env bash
# Regression test for the universal nightly macOS track.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

if ! awk '
  /^      - name: Build universal nightly app and Ghostty CLI helper \(Release\)/ { in_universal=1; next }
  in_universal && /^      - name:/ { in_universal=0 }
  in_universal && /-destination '\''generic\/platform=macOS'\''/ { saw_universal_destination=1 }
  in_universal && /ARCHS="arm64 x86_64"/ { saw_universal_archs=1 }
  in_universal && /ONLY_ACTIVE_ARCH=NO/ { saw_universal_only_active_arch=1 }
  in_universal && /COMPILATION_CACHE_ENABLE_CACHING=YES/ { saw_compilation_cache=1 }
  in_universal && /COMPILER_INDEX_STORE_ENABLE=NO/ { saw_index_disabled=1 }
  in_universal && /-showBuildTimingSummary/ { saw_timing_summary=1 }
  END {
    exit !(saw_universal_destination && saw_universal_archs && saw_universal_only_active_arch && saw_compilation_cache && saw_index_disabled && saw_timing_summary)
  }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must build the universal app with compilation caching, no index store, and timing output"
  exit 1
fi

if ! awk '
  /^      - name: Cache Xcode compilation results/ { in_cache=1; next }
  in_cache && /^      - name:/ { in_cache=0 }
  in_cache && /path: build-universal\/CompilationCache\.noindex/ { saw_path=1 }
  in_cache && /key: xcode-compilation-nightly-/ { saw_key=1 }
  in_cache && /steps\.compilation-cache-key\.outputs\.toolchain/ { saw_toolchain=1 }
  in_cache && /steps\.compilation-cache-key\.outputs\.utc_week/ { saw_week=1 }
  in_cache && /restore-keys:/ { saw_restore=1 }
  END { exit !(saw_path && saw_key && saw_toolchain && saw_week && !saw_restore) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must use one toolchain-scoped cache per week without stale fallback"
  exit 1
fi

if ! awk '
  /^      - name: Bound Xcode compilation cache size/ { in_bound=1; next }
  in_bound && /^      - name:/ { in_bound=0 }
  in_bound && /max_cache_kib=\$\(\(3 \* 1024 \* 1024\)\)/ { saw_limit=1 }
  in_bound && /rm -rf "\$cache_path"/ { saw_skip_save=1 }
  END { exit !(saw_limit && saw_skip_save) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must skip saving Xcode compilation caches larger than 3 GiB"
  exit 1
fi

if ! awk '
  /^      - name: Build universal nightly app and Ghostty CLI helper \(Release\)/ { in_helper=1; next }
  in_helper && /^      - name:/ { in_helper=0 }
  in_helper && /build-ghostty-cli-helper\.sh --universal/ { saw_build=1 }
  in_helper && /helper missing arm64 slice/ { saw_arm64_assert=1 }
  in_helper && /helper missing x86_64 slice/ { saw_x86_assert=1 }
  in_helper && /wait "\$HELPER_PID"/ { saw_wait=1 }
  in_helper && /cat "\$HELPER_LOG"/ { saw_log=1 }
  END { exit !(saw_build && saw_arm64_assert && saw_x86_assert && saw_wait && saw_log) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must build and verify the real universal Ghostty helper alongside the app build"
  exit 1
fi

if ! awk '
  /^      - name: Inject universal Ghostty CLI helper/ { in_inject=1; next }
  in_inject && /^      - name:/ { in_inject=0 }
  in_inject && /install -m 755 \/tmp\/cmux-ghostty-helper-universal "\$DEST"/ { saw_install=1 }
  END { exit !saw_install }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must inject the verified universal Ghostty helper into the app"
  exit 1
fi

if ! awk '
  /^      - name: Verify nightly binary architectures/ { in_verify=1; next }
  in_verify && /^      - name:/ { in_verify=0 }
  in_verify && /lipo -archs "\$APP_BINARY"/ { saw_app=1 }
  in_verify && /lipo -archs "\$CLI_BINARY"/ { saw_cli=1 }
  in_verify && /lipo -archs "\$HELPER_BINARY"/ { saw_helper=1 }
  in_verify && /\[\[ "\$APP_ARCHS" == \*arm64\* && "\$APP_ARCHS" == \*x86_64\* \]\]/ { saw_app_assert=1 }
  in_verify && /\[\[ "\$CLI_ARCHS" == \*arm64\* && "\$CLI_ARCHS" == \*x86_64\* \]\]/ { saw_cli_assert=1 }
  in_verify && /\[\[ "\$HELPER_ARCHS" == \*arm64\* && "\$HELPER_ARCHS" == \*x86_64\* \]\]/ { saw_helper_assert=1 }
  END { exit !(saw_app && saw_cli && saw_helper && saw_app_assert && saw_cli_assert && saw_helper_assert) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must verify universal app, CLI, and helper slices with lipo"
  exit 1
fi

if ! grep -Fq 'bundle ID `com.cmuxterm.app.nightly`' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must publish the unified nightly bundle ID"
  exit 1
fi

if ! grep -Fq 'cp appcast.xml appcast-universal.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must keep the compatibility appcast-universal.xml feed"
  exit 1
fi

if ! grep -Fq './scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" nightly appcast.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must generate the unified nightly appcast"
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
  in_upload && /uses: actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7/ { saw_upload=1 }
  in_upload && /cmux-nightly-macos\*\.dmg/ { saw_arm_artifacts=1 }
  in_upload && /appcast-universal\.xml/ { saw_universal_appcast=1 }
  END { exit !(saw_if && saw_upload && saw_arm_artifacts && saw_universal_appcast) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: non-main nightly runs must upload nightly artifacts and compatibility appcasts"
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
  in_publish && /cmux-nightly-macos-\$\{\{ github\.run_id \}\}\*\.dmg/ { saw_immutable=1 }
  in_publish && /cmux-nightly-macos\.dmg/ { saw_stable=1 }
  in_publish && /appcast-universal\.xml/ { saw_universal_appcast=1 }
  END { exit !(saw_publish_if && saw_immutable && saw_stable && saw_universal_appcast) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: main nightly publish must include immutable/stable assets and compatibility appcast"
  exit 1
fi

echo "PASS: nightly workflow keeps the universal nightly track guarded"
