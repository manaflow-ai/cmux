#!/usr/bin/env bash
# Regression test for the nightly macOS track: one universal build, thinned into per-architecture DMGs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

if ! awk '
  /^      - name: Build universal nightly app \(Release\)/ { in_universal=1; next }
  in_universal && /^      - name:/ { in_universal=0 }
  in_universal && /-destination '\''generic\/platform=macOS'\''/ { saw_universal_destination=1 }
  in_universal && /ARCHS="arm64 x86_64"/ { saw_universal_archs=1 }
  in_universal && /ONLY_ACTIVE_ARCH=NO/ { saw_universal_only_active_arch=1 }
  in_universal && /-quiet/ { saw_quiet=1 }
  in_universal && /COMPILATION_CACHE_ENABLE_CACHING=YES/ { saw_compilation_cache=1 }
  in_universal && /COMPILER_INDEX_STORE_ENABLE=NO/ { saw_index_disabled=1 }
  in_universal && /-showBuildTimingSummary/ { saw_timing_summary=1 }
  END {
    exit !(saw_universal_destination && saw_universal_archs && saw_universal_only_active_arch && !saw_quiet && saw_compilation_cache && saw_index_disabled && saw_timing_summary)
  }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must build the universal app with visible timing output, compilation caching, and no index store"
  exit 1
fi

if ! awk '
  /^  refresh-compilation-cache:/ { job="refresh"; next }
  /^  build-nightly-app:/ { job="build"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job && /^      - name: Cache Xcode compilation results/ { in_cache=1; next }
  in_cache && /^      - name:/ { in_cache=0 }
  in_cache && /path: build-universal\/CompilationCache\.noindex/ { saw_path[job]=1 }
  in_cache && /key: xcode-compilation-release-/ { saw_key[job]=1 }
  in_cache && /steps\.compilation-cache-key\.outputs\.toolchain/ { saw_toolchain[job]=1 }
  in_cache && /needs\.decide\.outputs\.head_sha/ { saw_head_sha[job]=1 }
  in_cache && /restore-keys:/ { saw_restore[job]=1 }
  END {
    exit !(saw_path["refresh"] && saw_key["refresh"] && saw_toolchain["refresh"] && saw_head_sha["refresh"] && saw_restore["refresh"] &&
           saw_path["build"] && saw_key["build"] && saw_toolchain["build"] && saw_head_sha["build"] && saw_restore["build"])
  }
' "$WORKFLOW_FILE"; then
  echo "FAIL: cache warming and nightly app builds must both roll the shared Release compilation cache forward by source revision"
  exit 1
fi

if ! grep -Fq 'cron: "17 */6 * * *"' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must refresh the shared Release cache four times daily"
  exit 1
fi

if ! grep -Fq 'cron: "47 8 * * *"' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must publish once daily at 08:47 UTC"
  exit 1
fi

if ! awk '
  /^  push:/ { in_push=1; next }
  in_push && /^  [a-zA-Z0-9_-]+:/ { in_push=0 }
  in_push && /^    branches:/ { saw_branches=1 }
  in_push && /^      - main$/ { saw_main=1 }
  END { exit !(saw_branches && saw_main) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: every push to main must trigger a Nightly publication attempt"
  exit 1
fi

if ! grep -Fq 'const headSha = context.sha;' "$WORKFLOW_FILE"; then
  echo "FAIL: each Nightly run must build the exact revision that triggered it"
  exit 1
fi

if grep -Fq 'github.rest.repos.getBranch' "$WORKFLOW_FILE"; then
  echo "FAIL: queued Nightly runs must not replace their triggering revision with a newer main HEAD"
  exit 1
fi

if ! awk '
  /^  refresh-compilation-cache:/ { in_refresh=1; next }
  in_refresh && /^  [a-zA-Z0-9_-]+:/ { in_refresh=0 }
  in_refresh && /timeout-minutes: 45/ { saw_cold_build_timeout=1 }
  in_refresh && /if: github\.event_name == '\''schedule'\'' && github\.event\.schedule == '\''17 \*\/6 \* \* \*'\''/ { saw_schedule_gate=1 }
  in_refresh && /runs-on: \$\{\{ vars\.MACOS_RUNNER_26_RELEASE/ { saw_release_runner=1 }
  in_refresh && /CMUX_CI_XCODE_APP_MACOS_26/ { saw_release_xcode=1 }
  in_refresh && /select-ci-xcode\.sh/ { saw_xcode_selection=1 }
  in_refresh && /^      - name: Look up Xcode compilation cache/ { saw_lookup=1 }
  in_refresh && /uses: actions\/cache\/restore@/ { saw_restore_action=1 }
  in_refresh && /lookup-only: true/ { saw_lookup_only=1 }
  in_refresh && /^      - name: Cache Xcode compilation results/ { saw_cache=1 }
  in_refresh && /^      - name: Refresh universal nightly compilation cache/ { saw_refresh=1 }
  in_refresh && /if: steps\.compilation-cache-lookup\.outputs\.cache-hit != '\''true'\''/ { saw_change_gate=1 }
  in_refresh && /-showBuildTimingSummary/ { saw_timing_summary=1 }
  in_refresh && /-quiet/ { saw_quiet=1 }
  END { exit !(saw_cold_build_timeout && saw_schedule_gate && saw_release_runner && saw_release_xcode && saw_xcode_selection && saw_lookup && saw_restore_action && saw_lookup_only && saw_cache && saw_refresh && saw_change_gate && saw_timing_summary && !saw_quiet) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the six-hour schedule must allow 45 minutes for a cold cache build and use the matching runner, Xcode, and visible timing output"
  exit 1
fi

if ! grep -Fq "if: needs.decide.outputs.should_build == 'true' && (github.event_name != 'schedule' || github.event.schedule == '47 8 * * *')" "$WORKFLOW_FILE"; then
  echo "FAIL: manual runs and the daily publish schedule must sign, notarize, and publish Nightly"
  exit 1
fi

if ! awk '
  /^      - name: Checkout build ref/ { in_checkout=1; next }
  in_checkout && /^      - name:/ { in_checkout=0 }
  in_checkout && /ref: \$\{\{ needs\.decide\.outputs\.head_sha \}\}/ { saw_fixed_sha=1 }
  END { exit !saw_fixed_sha }
' "$WORKFLOW_FILE"; then
  echo "FAIL: Nightly must build the fixed source revision selected by the decide job"
  exit 1
fi

if grep -Eq 'current_head_(prebuild|postbuild)|still_current' "$WORKFLOW_FILE"; then
  echo "FAIL: main advancing after dispatch must not skip a fixed Nightly candidate or report false-green publication"
  exit 1
fi

R2_UPLOAD_LINE="$(grep -nF -- '- name: Upload nightly appcasts to R2' "$WORKFLOW_FILE" | cut -d: -f1)"
TAG_MOVE_LINE="$(grep -nF -- '- name: Move nightly tag to built commit' "$WORKFLOW_FILE" | cut -d: -f1)"
if [ -z "$R2_UPLOAD_LINE" ] || [ -z "$TAG_MOVE_LINE" ] || [ "$TAG_MOVE_LINE" -le "$R2_UPLOAD_LINE" ]; then
  echo "FAIL: the nightly tag completion marker must move only after GitHub and R2 publication succeed"
  exit 1
fi

if ! awk '
  /^  refresh-compilation-cache:/ { job="refresh"; next }
  /^  build-nightly-app:/ { job="build"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job && /^      - name: Bound Xcode compilation cache size/ { in_bound=1; next }
  in_bound && /^      - name:/ { in_bound=0 }
  in_bound && /max_cache_kib=\$\(\(5 \* 1024 \* 1024\)\)/ { saw_limit[job]=1 }
  in_bound && /rm -rf "\$cache_path"/ { saw_skip_save[job]=1 }
  END { exit !(saw_limit["refresh"] && saw_skip_save["refresh"] && saw_limit["build"] && saw_skip_save["build"]) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: cache warming and nightly app builds must retain caches through 5 GiB and skip larger saves"
  exit 1
fi

CI_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"
if ! awk '
  /^  release-build:/ { in_release=1; next }
  in_release && /^  [a-zA-Z0-9_-]+:/ { in_release=0 }
  in_release && /path: build-universal\/CompilationCache\.noindex/ { saw_path=1 }
  in_release && /!build-universal\/CompilationCache\.noindex/ { saw_parent_exclusion=1 }
  in_release && /key: xcode-compilation-release-/ { saw_key=1 }
  in_release && /restore-keys:/ { saw_restore=1 }
  in_release && /COMPILATION_CACHE_ENABLE_CACHING=YES/ { saw_cache_flag=1 }
  in_release && /COMPILATION_CACHE_LIMIT_SIZE=3221225472/ { saw_runtime_limit=1 }
  in_release && /max_cache_kib=\$\(\(5 \* 1024 \* 1024\)\)/ { saw_save_limit=1 }
  in_release && /rm -rf "\$cache_path"/ { saw_skip_save=1 }
  END { exit !(saw_path && saw_parent_exclusion && saw_key && saw_restore && saw_cache_flag && saw_runtime_limit && saw_save_limit && saw_skip_save) }
' "$CI_WORKFLOW_FILE"; then
  echo "FAIL: PR release builds must restore and update the bounded cache warmed from main without archiving it twice"
  exit 1
fi

if ! awk '
  /^  build-nightly-ghostty-cli-helper:/ { job="helper"; next }
  /^  build-nightly-app:/ { job="app"; next }
  /^  build-sign-notarize-nightly:/ { job="publish"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "helper" && /runs-on: \$\{\{ vars\.MACOS_RUNNER_15/ { saw_helper_runner=1 }
  job == "helper" && /build-ghostty-cli-helper\.sh --universal/ { saw_build=1 }
  job == "helper" && /lipo .* -verify_arch arm64 x86_64/ { saw_arch_assert=1 }
  job == "helper" && /name: cmux-nightly-ghostty-cli-helper/ { saw_helper_artifact=1 }
  job == "app" && /runs-on: \$\{\{ vars\.MACOS_RUNNER_26_NIGHTLY_BUILD \|\| '\''blacksmith-12vcpu-macos-26'\'' \}\}/ { saw_app_runner=1 }
  job == "app" && /CMUX_CI_XCODE_APP_MACOS_26/ { saw_app_xcode=1 }
  job == "app" && /select-ci-xcode\.sh/ { saw_app_selection=1 }
  job == "app" && /name: cmux-nightly-unsigned-app/ { saw_app_artifact=1 }
  job == "app" && /tar -C "\$products" -czf "\$RUNNER_TEMP\/cmux-nightly-unsigned\.tar\.gz" cmux\.app/ { saw_app_only_archive=1 }
  job == "app" && /^      - name: Upload dSYMs to Sentry/ { saw_app_dsym_upload=1 }
  job == "publish" && /build-nightly-ghostty-cli-helper/ { saw_publish_needs_helper=1 }
  job == "publish" && /build-nightly-app/ { saw_publish_needs_app=1 }
  job == "publish" && /CMUX_CI_XCODE_APP_MACOS_26/ { saw_publish_xcode=1 }
  job == "publish" && /select-ci-xcode\.sh/ { saw_publish_selection=1 }
  job == "publish" && /name: cmux-nightly-unsigned-app/ { saw_app_download=1 }
  job == "publish" && /path: nightly-inputs\/app/ { saw_app_download_path=1 }
  job == "publish" && /tar -C "\$products" -xzf nightly-inputs\/app\/cmux-nightly-unsigned\.tar\.gz/ { saw_app_restore=1 }
  job == "publish" && /^      - name: Upload dSYMs to Sentry/ { saw_publish_dsym_upload=1 }
  END { exit !(saw_helper_runner && saw_build && saw_arch_assert && saw_helper_artifact && saw_app_runner && saw_app_xcode && saw_app_selection && saw_app_artifact && saw_app_only_archive && saw_app_dsym_upload && saw_publish_needs_helper && saw_publish_needs_app && saw_publish_xcode && saw_publish_selection && saw_app_download && saw_app_download_path && saw_app_restore && !saw_publish_dsym_upload) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly must build and hand off the macOS 15 helper and Xcode 26.5 app before publishing"
  exit 1
fi

if ! awk '
  /^      - name: Inject universal Ghostty CLI helper/ { in_inject=1; next }
  in_inject && /^      - name:/ { in_inject=0 }
  in_inject && /install -m 755 nightly-inputs\/ghostty\/ghostty "\$DEST"/ { saw_install=1 }
  END { exit !saw_install }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must inject the verified universal Ghostty helper into the app"
  exit 1
fi

if ! awk '
  /^  build-nightly-app:/ { job="build"; next }
  /^  build-sign-notarize-nightly:/ { job="publish"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "build" && /^      - name: Derive Sparkle public key from private key/ { derived_in_build=1 }
  job == "publish" && /^      - name: Derive Sparkle public key from private key/ { derived_in_publish=1 }
  job == "publish" && /echo "SPARKLE_PUBLIC_KEY=\$DERIVED_PUBLIC_KEY" >> "\$GITHUB_ENV"/ { exported_in_publish=1 }
  END { exit !(!derived_in_build && derived_in_publish && exported_in_publish) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the publishing job must derive and export the Sparkle public key it consumes"
  exit 1
fi

if ! awk '
  /^  build-sign-notarize-nightly:/ { job="publish"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "publish" && /variant: \$\{\{ fromJSON\(needs\.decide\.outputs\.variants\) \}\}/ { saw_matrix=1 }
  job == "publish" && /NIGHTLY_VARIANT: \$\{\{ matrix\.variant \}\}/ { saw_variant_env=1 }
  job == "publish" && /^      - name: Thin bundle to the variant architecture/ { in_thin=1; next }
  in_thin && /^      - name:/ { in_thin=0 }
  in_thin && /if: matrix\.variant != '\''universal'\''/ { saw_thin_gate=1 }
  in_thin && /thin-app-bundle\.sh build-universal\/Build\/Products\/Release\/cmux\.app "\$NIGHTLY_VARIANT"/ { saw_thin=1 }
  job == "publish" && /^      - name: Verify nightly binary architectures/ { in_verify=1; next }
  in_verify && /^      - name:/ { in_verify=0 }
  in_verify && /Contents\/MacOS\/cmux"/ { saw_app=1 }
  in_verify && /Contents\/Resources\/bin\/cmux"/ { saw_cli=1 }
  in_verify && /Contents\/Resources\/bin\/ghostty"/ { saw_helper=1 }
  in_verify && /Contents\/Resources\/bin\/cmux-tui"/ { saw_tui=1 }
  in_verify && /\[\[ "\$archs" == \*arm64\* && "\$archs" == \*x86_64\* \]\]/ { saw_universal_assert=1 }
  in_verify && /\[ "\$archs" = "\$NIGHTLY_VARIANT" \]/ { saw_thin_assert=1 }
  in_verify && /Mach-O universal/ { saw_fat_scan=1 }
  END { exit !(saw_matrix && saw_variant_env && saw_thin_gate && saw_thin && saw_app && saw_cli && saw_helper && saw_tui && saw_universal_assert && saw_thin_assert && saw_fat_scan) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must thin each variant from the universal build and verify every bundled binary matches the variant architecture"
  exit 1
fi

if ! awk '
  /^      - name: Run CLI version memory guard regression/ { guard_line=NR }
  /^      - name: Thin bundle to the variant architecture/ { thin_line=NR }
  END { exit !(guard_line && thin_line && guard_line < thin_line) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the CLI memory guard must run on the universal bundle before thinning, so x86_64 variants never need Rosetta on the runner"
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

if ! grep -Fq './scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" nightly "$NIGHTLY_APPCAST"' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must generate one appcast per variant"
  exit 1
fi

if ! awk '
  /NIGHTLY_APPCAST="appcast-\$\{NIGHTLY_VARIANT\}\.xml"/ { saw_thin_feed=1 }
  /NIGHTLY_APPCAST="appcast\.xml"/ { saw_legacy_feed=1 }
  /"https:\/\/files\.cmux\.com\/nightly\/\$\{NIGHTLY_APPCAST\}"/ { saw_feed_injection=1 }
  /NIGHTLY_DMG_IMMUTABLE="cmux-nightly-macos-\$\{NIGHTLY_VARIANT\}-\$\{NIGHTLY_BUILD\}\.dmg"/ { saw_immutable_name=1 }
  END { exit !(saw_thin_feed && saw_legacy_feed && saw_feed_injection && saw_immutable_name) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: each variant must bake its own feed URL and immutable DMG name"
  exit 1
fi

if ! awk '
  /^      - name: Assemble legacy nightly names/ { in_legacy=1; next }
  in_legacy && /^      - name:/ { in_legacy=0 }
  in_legacy && /cp cmux-nightly-macos-universal\.dmg cmux-nightly-macos\.dmg/ { saw_universal_legacy=1 }
  in_legacy && /cp cmux-nightly-macos-x86_64\.dmg cmux-nightly-macos\.dmg/ { saw_intel_legacy=1 }
  in_legacy && /cp appcast-x86_64\.xml appcast\.xml/ { saw_intel_feed=1 }
  END { exit !(saw_universal_legacy && saw_intel_legacy && saw_intel_feed) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the legacy nightly DMG and feed must serve the universal build during the transition and the x86_64 build afterwards"
  exit 1
fi

if ! grep -Fq 'NIGHTLY_LEGACY_UNIVERSAL_UNTIL: "20' "$WORKFLOW_FILE"; then
  echo "FAIL: the universal legacy build must have a dated retirement"
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
  in_upload && /appcast\*\.xml/ { saw_appcasts=1 }
  END { exit !(saw_if && saw_upload && saw_arm_artifacts && saw_appcasts) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: non-main nightly runs must upload every nightly DMG and appcast"
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
  in_publish && /cmux-nightly-macos-\*-\$\{\{ github\.run_id \}\}\*\.dmg/ { saw_immutable=1 }
  in_publish && /cmux-nightly-macos\.dmg/ { saw_stable=1 }
  in_publish && /cmux-nightly-macos-arm64\.dmg/ { saw_arm=1 }
  in_publish && /cmux-nightly-macos-x86_64\.dmg/ { saw_intel=1 }
  in_publish && /appcast-arm64\.xml/ { saw_arm_appcast=1 }
  in_publish && /appcast-x86_64\.xml/ { saw_intel_appcast=1 }
  in_publish && /appcast-universal\.xml/ { saw_universal_appcast=1 }
  END { exit !(saw_publish_if && saw_immutable && saw_stable && saw_arm && saw_intel && saw_arm_appcast && saw_intel_appcast && saw_universal_appcast) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: main nightly publish must include per-architecture immutable and stable DMGs, their appcasts, and the legacy names"
  exit 1
fi

echo "PASS: nightly workflow builds once, thins per architecture, and keeps the legacy track migrating"
