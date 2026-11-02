#!/usr/bin/env bash
# nightly.yml refresh-compilation-cache: "Refresh universal nightly compilation cache". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
# The warmer only fills the Swift compilation cache; the Chromium
# engine is a prebuilt artifact the shipped build embeds itself.
# Bundle cmux-tui bundles none (deferred): this build only fills the cache.
fleet_cache_settings=()
while IFS= read -r setting; do
  fleet_cache_settings+=("$setting")
done < <(bash scripts/ci/fleet-compilation-cache.sh)
CMUX_NEXT_TUI_MODE=deferred CMUX_NEXT_SKIP_CEF=1 CMUX_SKIP_ZIG_BUILD=1 xcodebuild -scheme cmux -configuration Release -derivedDataPath build-universal \
  -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath .spm-cache \
  -packageCachePath "$PWD/.spm-cache/.package-cache" \
  -showBuildTimingSummary \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  COMPILATION_CACHE_ENABLE_CACHING=YES \
  COMPILATION_CACHE_LIMIT_SIZE=3221225472 \
  "${fleet_cache_settings[@]}" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly build
