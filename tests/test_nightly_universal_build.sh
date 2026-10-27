#!/usr/bin/env bash
# Regression test for the normal nightly macOS track and its fast arm64 dogfood path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# nightly.yml with its scripts/ci/nightly-steps/ step scripts inline (tests/nightly_workflow_text.py).
WORKFLOW_FILE="$(mktemp "${TMPDIR:-/tmp}/nightly-expanded.XXXXXX")"
python3 "$ROOT_DIR/tests/nightly_workflow_text.py" > "$WORKFLOW_FILE"
trap 'rm -f "$WORKFLOW_FILE"' EXIT

if ! awk '
  /^      - name: Build nightly app \(Release\)/ { in_build=1; next }
  in_build && /^      - name:/ { in_build=0 }
  in_build && /run-xcodebuild-with-diagnostics\.sh --/ { saw_wrapper=1 }
  in_build && /xcodebuild -jobs / { saw_jobs_cap=1 }
  END { exit !(saw_wrapper && !saw_jobs_cap) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly Release builds must retain failure diagnostics and must not cap xcodebuild concurrency (a -jobs cap serializes the per-arch whole-module compiles)"
  exit 1
fi

if ! awk '
  /^      - name: Build (universal nightly app|nightly app) \(Release\)/ { in_universal=1; next }
  in_universal && /^      - name:/ { in_universal=0 }
  in_universal && /-destination '\''generic\/platform=macOS'\''/ { saw_universal_destination=1 }
  in_universal && (/ARCHS="arm64 x86_64"/ || /archs="arm64 x86_64"/) { saw_universal_archs=1 }
  in_universal && (/ONLY_ACTIVE_ARCH=NO/ || /only_active="NO"/) { saw_universal_only_active_arch=1 }
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
  /^      - name: Build nightly app \(Release\)/ { in_build=1; next }
  in_build && /^      - name:/ { in_build=0 }
  in_build && /notary_test_flags=\(build\)/ { saw_default=1 }
  in_build && /notary_test_flags=/ && /OTHER_SWIFT_FLAGS/ && /build\)/ { saw_notary=1 }
  in_build && /"\$\{notary_test_flags\[@\]\}" build/ { saw_unsafe_empty_expansion=1 }
  END { exit !(saw_default && saw_notary && !saw_unsafe_empty_expansion) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must make notary-test xcodebuild arguments non-empty under bash -u"
  exit 1
fi

if ! awk '
  /^      - name: Upload unsigned nightly app$/ { in_upload=1; next }
  in_upload && /^      - name:/ { in_upload=0 }
  in_upload && /compression-level: 0/ { found=1 }
  END { exit !found }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the precompressed unsigned app artifact must disable a second compression pass"
  exit 1
fi

if ! awk '
  /^  refresh-compilation-cache:/ { job="refresh"; next }
  /^  build-nightly-app:/ { job="build"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job && /^      - name: Restore Xcode compilation cache/ { in_cache=1; next }
  in_cache && /^      - name:/ { in_cache=0 }
  in_cache && /path: build-universal\/CompilationCache\.noindex/ { saw_path[job]=1 }
  in_cache && /key: xcode-compilation-release-/ { saw_key[job]=1 }
  in_cache && /steps\.compilation-cache-key\.outputs\.toolchain/ { saw_toolchain[job]=1 }
  # The warmer keys by the tip it builds; the app build by the resolved build_sha it builds.
  job == "refresh" && in_cache && /needs\.decide\.outputs\.head_sha/ { saw_head_sha[job]=1 }
  job == "build" && in_cache && /needs\.resolve-nightly-cmux-tui-client\.outputs\.build_sha/ { saw_head_sha[job]=1 }
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

if ! awk '
  /^  decide:/ { in_decide=1; next }
  in_decide && /^  [a-zA-Z0-9_-]+:/ { in_decide=0 }
  in_decide && /^    runs-on: .*vars\.LINUX_RUNNER.*blacksmith-4vcpu-ubuntu-2404/ { saw_runner_override=1 }
  END { exit !saw_runner_override }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the short nightly decide gate must use the pooled Linux route with a Blacksmith fallback"
  exit 1
fi

if ! awk '
  /^      - name: Download signing inputs \(parallel\)/ { in_download=1; next }
  in_download && /^      - name:/ { in_download=0 }
  in_download && /id: signing-inputs-parallel/ { saw_id=1 }
  in_download && /download-run-artifact.py/ { downloads++ }
  in_download && /--name cmux-nightly-unsigned-app --out nightly-inputs\/app/ { saw_app_download=1 }
  in_download && /--connections 64/ { saw_app_connections=1 }
  in_download && /app_ok=/ { saw_app_output=1 }
  in_download && /daemon_ok=/ { saw_daemon_output=1 }
  in_download && /helper_ok=/ { saw_helper_output=1 }
  END { exit !(saw_id && downloads >= 3 && saw_app_download && saw_app_connections && saw_app_output && saw_daemon_output && saw_helper_output) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly signers must fetch all inputs concurrently and give the large app artifact 64 ranged connections"
  exit 1
fi

for fallback in \
  "steps.signing-inputs-parallel.outputs.app_ok != 'true'" \
  "steps.signing-inputs-parallel.outputs.daemon_ok != 'true'" \
  "steps.signing-inputs-parallel.outputs.helper_ok != 'true'"; do
  if ! grep -Fq "$fallback" "$WORKFLOW_FILE"; then
    echo "FAIL: nightly signing input fallback is missing: $fallback"
    exit 1
  fi
done

if ! awk '
  /^  prepare-nightly-variant-primary:/ { in_prepare=1; next }
  in_prepare && /^  [a-zA-Z0-9_-]+:/ { in_prepare=0 }
  in_prepare && /runs-on: \$\{\{ github\.repository_owner/ { saw_matrix_runner=1 }
  in_prepare && /strategy:/ { saw_serial_fallback=1 }
  in_prepare && /PREPARE_FALLBACK/ { saw_runner_matrix=1; saw_primary_tolerated=1 }
  in_prepare && /blacksmith-4vcpu-ubuntu-2404/ { saw_blacksmith=1 }
  in_prepare && /env\.PREPARE_FALLBACK == '\''true'\''/ { saw_fallback=1 }
  in_prepare && /actions\/runs\/\$GITHUB_RUN_ID\/artifacts\?name=/ { saw_artifact_probe=1 }
  in_prepare && /steps\.reuse\.outputs\.exists != '\''true'\''/ { saw_reuse_gate=1 }
  END { exit !(saw_matrix_runner && saw_runner_matrix && saw_serial_fallback && saw_blacksmith && saw_fallback && saw_primary_tolerated && saw_artifact_probe && saw_reuse_gate) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly preparation must run on Blacksmith Linux, keep its fallback, and reuse a successful artifact"
  exit 1
fi
if ! awk '
  /^  prepare-nightly-variant-fallback:/ { in_fallback=1 }
  in_fallback && /needs: .*prepare-nightly-variant-primary/ { saw_dependency=1 }
  in_fallback && /result == '\''failure'\''/ { saw_failure_gate=1 }
  END { exit !(saw_dependency && saw_failure_gate) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the nightly fallback preparation must depend on a failed primary preparation"
  exit 1
fi

if ! grep -Fq '30 GiB required' "$WORKFLOW_FILE" && ! grep -Fq '30 GiB' "$WORKFLOW_FILE"; then
  echo "FAIL: the nightly disk floor contract must remain explicit; do not lower it to make a host pass"
  exit 1
fi

if grep -Fq 'github.rest.repos.getBranch' "$WORKFLOW_FILE"; then
  echo "FAIL: queued Nightly runs must not replace their triggering revision with a newer main HEAD"
  exit 1
fi

if ! awk -v refresh_runner="runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || 'blacksmith-6vcpu-macos-26' }}" '
  /^  refresh-compilation-cache:/ { in_refresh=1; next }
  in_refresh && /^  [a-zA-Z0-9_-]+:/ { in_refresh=0 }
  in_refresh && /timeout-minutes: 90/ { saw_cold_build_timeout=1 }
  in_refresh && /if: github\.event_name == '\''schedule'\'' && github\.event\.schedule == '\''17 \*\/6 \* \* \*'\''/ { saw_schedule_gate=1 }
  # Match the whole expression, not a prefix of it. `.*vars\.NAME` also matches
  # the ungated form, so this guard would keep passing if somebody dropped the
  # paid-overflow gate from the lane it exists to pin.
  in_refresh && index($0, refresh_runner) { saw_release_runner=1 }
  in_refresh && /CMUX_CI_XCODE_APP_MACOS_26/ { saw_release_xcode=1 }
  in_refresh && /select-ci-xcode\.sh/ { saw_xcode_selection=1 }
  in_refresh && /^      - name: Restore Xcode compilation cache/ { saw_lookup=1 }
  in_refresh && /uses: (actions\/cache\/restore@|\.\/\.github\/actions\/cache-restore$)/ { saw_restore_action=1 }
  in_refresh && /id: compilation-cache-restore/ { saw_restore_id=1 }
  in_refresh && /^      - name: Save Xcode compilation cache/ { saw_cache=1 }
  in_refresh && /^      - name: Refresh universal nightly compilation cache/ { saw_refresh=1 }
  in_refresh && /if: steps\.compilation-cache-restore\.outputs\.cache-hit != '\''true'\''/ { saw_change_gate=1 }
  in_refresh && /-showBuildTimingSummary/ { saw_timing_summary=1 }
  in_refresh && /-quiet/ { saw_quiet=1 }
  END { exit !(saw_cold_build_timeout && saw_schedule_gate && saw_release_runner && saw_release_xcode && saw_xcode_selection && saw_lookup && saw_restore_action && saw_restore_id && saw_cache && saw_refresh && saw_change_gate && saw_timing_summary && !saw_quiet) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the six-hour schedule must allow 90 minutes for a cold cache build and use the matching runner, Xcode, and visible timing output"
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

R2_UPLOAD_LINE="$(grep -nF -- '- name: Upload nightly appcasts to R2' "$WORKFLOW_FILE" | cut -d: -f1 || true)"
MARKER_LINE="$(grep -nF -- '- name: Record verified nightly publication' "$WORKFLOW_FILE" | cut -d: -f1 || true)"
TAG_MOVE_LINE="$(grep -nF -- '- name: Move channel release tag to built commit' "$WORKFLOW_FILE" | cut -d: -f1 || true)"
if [ -z "$R2_UPLOAD_LINE" ] || [ -z "$MARKER_LINE" ] || [ -z "$TAG_MOVE_LINE" ] \
  || [ "$MARKER_LINE" -le "$R2_UPLOAD_LINE" ] || [ "$TAG_MOVE_LINE" -le "$MARKER_LINE" ]; then
  echo "FAIL: the nightly publication marker and tag must move only after GitHub and R2 publication succeed"
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

CI_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos.yml"
# A cache saved from a pull request is readable only by that pull request, and
# each save pushes the main seeds out of a size-capped store. Pull request
# Release builds read the cache warmed from main and never write one.
if ! awk '
  /^  release-build:/ { in_release=1; next }
  in_release && /^  [a-zA-Z0-9_-]+:/ { in_release=0 }
  in_release && /uses: (actions\/cache|\.\/\.github\/actions\/cache-)/ && !/uses: (actions\/cache\/restore@|\.\/\.github\/actions\/cache-restore$)/ { saw_save=1 }
  in_release && /path: build-universal\/CompilationCache\.noindex/ { saw_path=1 }
  in_release && /key: deriveddata-/ { saw_deriveddata=1 }
  in_release && /key: xcode-compilation-release-/ { saw_key=1 }
  in_release && /restore-keys:/ { saw_restore=1 }
  in_release && /COMPILATION_CACHE_ENABLE_CACHING=YES/ { saw_cache_flag=1 }
  in_release && /COMPILATION_CACHE_LIMIT_SIZE=3221225472/ { saw_runtime_limit=1 }
  END { exit !(saw_path && !saw_deriveddata && saw_key && saw_restore && saw_cache_flag && saw_runtime_limit && !saw_save) }
' "$CI_WORKFLOW_FILE"; then
  echo "FAIL: PR release builds must restore the cache warmed from main read-only and must not cache DerivedData"
  exit 1
fi

if ! awk -v helper_runner="runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || inputs.nightly_next_unsigned_run != '' && 'ubuntu-24.04' || needs.resolve-nightly-ghostty-cli-helper.outputs.hit == 'true' && (vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404') || github.repository == 'manaflow-ai/cmux' && github.run_attempt == 1 && (github.event_name == 'push' || github.event_name == 'schedule') && vars.CI_PR_POOL_OWNED == '1' && (github.ref == 'refs/heads/main' && vars.CI_SEED_TRUSTED_POOL || github.ref == 'refs/heads/nightly-next' && vars.CI_SIDE_LANE_RUNNER) || 'blacksmith-6vcpu-macos-26' }}" \
       '
  /^  build-nightly-ghostty-cli-helper:/ { job="helper"; next }
  /^  build-nightly-app:/ { job="app"; next }
  /^  prepare-nightly-variant-primary:/ { job="publish"; next }
  /^  build-sign-notarize-nightly:/ { job="publish"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  # A reused helper leaves this job on Linux; a fresh one builds on owned
  # macOS 26 (Zig 0.16.0, SDK 26), then Blacksmith macOS 26; never macOS 15
  # or a GitHub-hosted Mac. Match the whole expression.
  job == "helper" && index($0, helper_runner) { saw_helper_runner=1 }
  job == "helper" && /build-ghostty-cli-helper\.sh --universal/ { saw_build=1 }
  job == "helper" && /lipo .* -verify_arch arm64 x86_64/ { saw_arch_assert=1 }
  job == "helper" && /name: cmux-nightly-ghostty-cli-helper/ { saw_helper_artifact=1 }
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
  job == "publish" && /tar (--warning=no-unknown-keyword )?-C "\$products" -xzf nightly-inputs\/app\/cmux-nightly-unsigned\.tar\.gz/ { saw_app_restore=1 }
  job == "publish" && /^      - name: Upload dSYMs to Sentry/ { saw_publish_dsym_upload=1 }
  END { exit !(saw_helper_runner && saw_build && saw_arch_assert && saw_helper_artifact && saw_app_xcode && saw_app_selection && saw_app_artifact && saw_app_only_archive && saw_app_dsym_upload && saw_publish_needs_helper && saw_publish_needs_app && saw_publish_xcode && saw_publish_selection && saw_app_download && saw_app_download_path && saw_app_restore && !saw_publish_dsym_upload) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly must build and hand off the macOS 26 helper and Xcode 26.5 app before publishing"
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
  /^  prepare-nightly-variant-primary:/ { job="publish"; next }
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
  /^  prepare-nightly-variant-primary:/ { job="publish"; next }
  /^  build-sign-notarize-nightly:/ { job="publish"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "publish" && /variant: \$\{\{ fromJSON\(needs\.decide\.outputs\.variants\) \}\}/ { saw_matrix=1 }
  job == "publish" && /NIGHTLY_VARIANT: \$\{\{ matrix\.variant \}\}/ { saw_variant_env=1 }
  job == "publish" && /^      - name: Thin bundle to the variant architecture/ { in_thin=1; next }
  in_thin && /^      - name:/ { in_thin=0 }
  in_thin && /matrix\.variant != '\''universal'\''/ { saw_thin_gate=1 }
  in_thin && /thin-app-bundle\.sh build-universal\/Build\/Products\/Release\/cmux\.app "\$NIGHTLY_VARIANT"/ { saw_thin=1 }
  job == "publish" && /^      - name: Verify nightly binary architectures/ { in_verify=1; next }
  in_verify && /^      - name:/ { in_verify=0 }
  in_verify && /Contents\/MacOS\/cmux"/ { saw_app=1 }
  in_verify && /Contents\/Resources\/bin\/cmux"/ { saw_cli=1 }
  in_verify && /Contents\/Resources\/bin\/ghostty"/ { saw_helper=1 }
  # bin/cmux-tui and bin/acpmux are symlinks to bin/cmux, checked with readlink.
  in_verify && /for alias in cmux-tui acpmux; do/ { saw_aliases=1 }
  in_verify && /readlink "\$APP\/Contents\/Resources\/bin\/\$alias"\)" = cmux/ { saw_tui=saw_aliases }
  in_verify && /\[\[ "\$archs" == \*arm64\* && "\$archs" == \*x86_64\* \]\]/ { saw_universal_assert=1 }
  in_verify && /\[ "\$archs" = "\$NIGHTLY_VARIANT" \]/ { saw_thin_assert=1 }
  in_verify && /Mach-O universal/ { saw_fat_scan=1 }
  END { exit !(saw_matrix && saw_variant_env && saw_thin_gate && saw_thin && saw_app && saw_cli && saw_helper && saw_tui && saw_universal_assert && saw_thin_assert && saw_fat_scan) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must thin each variant from the universal build and verify every bundled binary matches the variant architecture"
  exit 1
fi

if ! grep -Fq "bundleId: 'com.cmuxterm.app.nightly'," "$WORKFLOW_FILE" || ! grep -Fq "bundleId: 'com.cmuxterm.app.rc'," "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must publish the unified nightly bundle ID and the rc channel bundle ID"
  exit 1
fi

if ! grep -Fq 'cp appcast.xml appcast-universal.xml' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must keep the compatibility appcast-universal.xml feed"
  exit 1
fi

if ! grep -Fq './scripts/sparkle_generate_appcast.sh "$NIGHTLY_DMG_IMMUTABLE" "$CHANNEL_RELEASE_TAG" "$NIGHTLY_APPCAST"' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly workflow must generate one appcast per variant"
  exit 1
fi
if ! awk '
  /^  build-sign-notarize-nightly:/ { job="sign"; next }
  /^  generate-nightly-deltas:/ { job="delta"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "sign" && /SPARKLE_PREVIOUS_ARCHIVES_DIR|SPARKLE_MAXIMUM_DELTAS/ { initial_delta=1 }
  job == "delta" && /scripts\/ci\/generate-nightly-deltas\.sh/ { saw_deltas=1 }
  job == "delta" && /name: cmux-nightly-deltas-\$\{\{ matrix\.variant \}\}/ { saw_artifact=1 }
  END { exit !(saw_deltas && saw_artifact && !initial_delta) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: initial appcasts must be full-only and delta generation must run later per variant"
  exit 1
fi

if ! awk '
  /^  generate-nightly-deltas:/ { delta=NR; next }
  /^  republish-nightly-deltas:/ { republish=NR; next }
  /^  publish-nightly:/ { publish=NR; next }
  /^  report-nightly-failure:/ { report=NR; next }
  END { exit !(publish && delta && republish && publish < delta && delta < republish && report > republish) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: Sparkle deltas must be downstream of first publication and before failure closeout"
  exit 1
fi

if ! awk '
  /^  generate-nightly-deltas:/ { job="delta"; next }
  /^  republish-nightly-deltas:/ { job="republish"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "delta" && /needs: \[decide, build-nightly-app, resolve-nightly-cmux-tui-client, publish-nightly(, pick-nightly-sign-runner)?\]/ { saw_publish_need=1 }
  job == "delta" && /fail-fast: false/ { saw_matrix=1 }
  job == "republish" && /needs: \[decide, build-nightly-app, resolve-nightly-cmux-tui-client, publish-nightly, generate-nightly-deltas\]/ { saw_delta_need=1 }
  # The tag itself: commits/<name> resolves a same-named branch (cx-urd.67).
  job == "republish" && /gh api .*git\/ref\/tags\/\$CHANNEL_RELEASE_TAG/ { saw_guard=1 }
  job == "republish" && /gh api .*commits\/\$CHANNEL_RELEASE_TAG/ { saw_branch_read=1 }
  # The publication moves the tag to the resolved build commit, not the tip.
  job == "republish" && index($0, "\"$current_sha\" != \"${{ needs.resolve-nightly-cmux-tui-client.outputs.build_sha }}\"") { saw_build_sha=1 }
  job == "republish" && /publish-release-assets\.py/ { saw_republish=1 }
  job == "republish" && /Upload revised appcasts to R2/ { saw_r2=1 }
  END { exit !(saw_publish_need && saw_matrix && saw_delta_need && saw_guard && !saw_branch_read && saw_build_sha && saw_republish && saw_r2) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: post-publication delta generation must be matrixed, stale-guarded, and republished to GitHub and R2"
  exit 1
fi

if ! awk '
  /^  build-nightly-app:/ { job="app"; next }
  /^  build-sign-notarize-nightly:/ { job="sign"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "app" && /Clear build outputs a persistent runner kept/ { in_clear=1; next }
  in_clear && /^      - name:/ { in_clear=0 }
  in_clear && /clear-dirs\.sh remote-daemon-assets/ { saw_clear=1 }
  job == "app" && /^      - name: Start Release DerivedData empty/ { in_prepare=1; saw_prepare=1; next }
  in_prepare && /^      - name:/ { in_prepare=0 }
  in_prepare && /clear-dirs\.sh build-universal/ { saw_clear_dd=1 }
  in_prepare && /track \}\}" = nightly-next/ && !saw_clear_dd { next_first=1 }
  in_prepare && /ln -s/ { saw_link=1 }
  job == "app" && /cmux-nightly-\$\{\{ needs\.decide\.outputs\.channel \}\}-\$\{toolchain_key\}/ { saw_key=1 }
  job == "app" && /^      - name: Restore Xcode compilation cache/ && !saw_clear_dd { restore_first=1 }
  job == "app" && /^      - name: Build nightly app \(Release\)/ { saw_build=1 }
  job == "app" && !saw_build && /ln -s .*build-universal/ { saw_link=1 }
  job == "app" && !saw_build && /persistent Release DerivedData/ { saw_persistent=1 }
  job == "app" && /nightly_build_state\.py (replay|record)/ { saw_replay=1 }
  END { exit !(saw_clear && saw_prepare && saw_clear_dd && !restore_first && !next_first && !saw_link && !saw_key && !saw_persistent && !saw_replay) }
' "$WORKFLOW_FILE"; then
  # An incremental build can keep stale autolink and force-load data in
  # objects it did not recompile after an import set changed. The shipped app
  # must start from empty DerivedData with its inputs at their checkout times;
  # only the content-keyed compilation cache (restored into it) and the Swift
  # package checkouts may be warm.
  echo "FAIL: the shipped nightly build must start from empty Release DerivedData, never a persistent tree or replayed input times"
  exit 1
fi

if ! awk '
  /NIGHTLY_APPCAST="appcast-\$\{NIGHTLY_VARIANT\}\.xml"/ { saw_thin_feed=1 }
  /NIGHTLY_APPCAST="appcast\.xml"/ { saw_legacy_feed=1 }
  /"\$\{CHANNEL_FEED_BASE\}\/\$\{NIGHTLY_APPCAST\}"/ { saw_feed_injection=1 }
  /feedBase: .https:\/\/files\.cmux\.com\/nightly.,/ { saw_nightly_feed_base=1 }
  /feedBase: .https:\/\/files\.cmux\.com\/rc.,/ { saw_rc_feed_base=1 }
  /NIGHTLY_DMG_IMMUTABLE="\$\{CHANNEL_DMG_PREFIX\}-\$\{NIGHTLY_VARIANT\}-\$\{NIGHTLY_BUILD\}\.dmg"/ { saw_immutable_name=1 }
  END { exit !(saw_thin_feed && saw_legacy_feed && saw_feed_injection && saw_nightly_feed_base && saw_rc_feed_base && saw_immutable_name) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: each variant must bake its own feed URL and immutable DMG name"
  exit 1
fi

if ! awk '
  /^      - name: Assemble legacy nightly names/ { in_legacy=1; next }
  in_legacy && /^      - name:/ { in_legacy=0 }
  in_legacy && /cp "\$\{CHANNEL_DMG_PREFIX\}-universal\.dmg" "\$\{CHANNEL_DMG_PREFIX\}\.dmg"/ { saw_universal_legacy=1 }
  in_legacy && /\$\{CHANNEL_DMG_PREFIX\}-x86_64\.dmg" "\$\{CHANNEL_DMG_PREFIX\}\.dmg/ { saw_intel_legacy=1 }
  END { exit !(saw_universal_legacy && !saw_intel_legacy) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: the legacy nightly DMG and feed must stay universal: browsers cannot pick an architecture, the app can"
  exit 1
fi

# nightly-next ships arm64 only (tests/test_nightly_next_arm64_only.py); main's nightly keeps all three.
if ! grep -Fq "const variants = fastBuild || track === 'nightly-next' ? ['arm64'] : ['arm64', 'x86_64', 'universal'];" "$WORKFLOW_FILE"; then
  echo "FAIL: main's nightly must always build the universal download alongside the thin update tracks"
  exit 1
fi

if ! grep -Fq 'description: Build one arm64 dogfood DMG without Intel or Sparkle delta work' "$WORKFLOW_FILE"; then
  echo "FAIL: workflow dispatch must expose the fast arm64 dogfood build"
  exit 1
fi

# cmux-next ships no Cloud tunnel system extension. It does ship the Computer
# Use helper (D19; tests/test_nightly_next_computer_use_helper.py). The
# Chromium engine artifact is arm64 only, so an x86_64 variant drops it before
# thinning.
if grep -Eq 'Cloud tunnel|SystemExtensions|tunnel-extension' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly still handles the legacy tunnel extension"
  exit 1
fi
if ! awk '
  /drop-cef-without-arch\.sh build-universal\/Build\/Products\/Release\/cmux\.app "\$NIGHTLY_VARIANT"/ { drop_line=NR }
  /thin-app-bundle\.sh build-universal\/Build\/Products\/Release\/cmux\.app "\$NIGHTLY_VARIANT"/ { thin_line=NR }
  END { exit !(drop_line && thin_line && drop_line < thin_line) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly must drop an arm64-only Chromium engine before thinning a variant"
  exit 1
fi

# Nightly distribution verification launches no app or CLI. The signed-app and
# final-DMG jobs retain deterministic artifact and sidecar protocol checks and
# gate publication, while app behavior stays in the path-routed integration lane.
if ! awk '
  /^  verify-signed-nightly:/ { job="verify"; next }
  /^  verify-final-dmg-nightly:/ { job="verify-dmg"; dmg_job=1; next }
  /^  publish-nightly:/ { job="publish"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "verify" && /^    environment:/ { verify_env=1 }
  job == "verify" && /secrets\./ { verify_secret=1 }
  job == "verify" && /verify-diff-sidecar-artifact\.sh/ { sidecar=1 }
  job == "verify-dmg" && /^      - name: Verify final DMG artifact$/ { dmg=1 }
  job == "verify-dmg" && /verify-dmg-artifact\.sh/ { static_dmg=1 }
  job == "publish" && /needs: .*verify-final-dmg-nightly/ { dmg_gated=1 }
  job == "publish" && /needs: .*verify-signed-nightly/ { gated=1 }
  END { exit !(sidecar && static_dmg && gated && dmg_job && dmg && dmg_gated && !verify_env && !verify_secret) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly must use secret-free static verification jobs that gate publication, with no runtime smoke"
  exit 1
fi

if grep -Eq 'smoke-launch|smoke-signed-app-cli|smoke-dmg' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly publication workflows must contain no smoke-shaped runtime checks"
  exit 1
fi

# Published nightly-next waits for Apple in the job for 20m (main and RC 40m),
# so one stalled submission never holds the next build: Accepted builds are stapled and published by this run,
# and a wait that runs out hands the exact submission to the next nightly-next
# run through the recovery artifact. Nothing unaccepted reaches distribution
# policy, the appcast or publication.
for expected in \
  "id: notarize-nightly" \
  "CMUX_NOTARY_WAIT_TIMEOUT: \${{ needs.decide.outputs.notary_test == 'true' && '160m' || needs.decide.outputs.track == 'nightly-next' && needs.decide.outputs.should_publish == 'true' && needs.decide.outputs.no_publish != 'true' && '20m' || '40m' }}" \
  "CMUX_NOTARY_PENDING_ON_TIMEOUT: \${{ needs.decide.outputs.track == 'nightly-next' && needs.decide.outputs.should_publish == 'true' && needs.decide.outputs.no_publish != 'true' && 'true' || 'false' }}" \
  "notary_pending: \${{ steps.notarize-nightly.outputs.submission_pending }}" \
  "- name: Prepare pending notarization recovery artifact" \
  "- name: Upload pending notarization recovery artifact"; do
  if ! grep -Fq -- "$expected" "$WORKFLOW_FILE"; then
    echo "FAIL: nightly-next bounded notarization contract is missing: $expected"
    exit 1
  fi
done
if grep -Fq "CMUX_NOTARY_SUBMIT_ONLY:" "$WORKFLOW_FILE"; then
  echo "FAIL: published nightly-next must wait for Apple in the job, not submit only"
  exit 1
fi
ACCEPTED_ONLY="needs.decide.outputs.fast_build != 'true' && needs.decide.outputs.notary_paused != 'true' && steps.notarize-nightly.outputs.submission_pending != 'true'"
# A cx-f58x notary test is public-repo diagnostic output: no appcast, no DMG artifact.
NOT_NOTARY_TEST="$ACCEPTED_ONLY && needs.decide.outputs.notary_test != 'true'"
for step in "Gate distribution with syspolicy_check" "Generate Sparkle appcasts (nightly)" "Upload nightly variant artifacts"; do
  step_if="$(awk -v name="      - name: $step" '$0 == name { found=1; next } found && /^        if: / { sub(/^        if: /, ""); print; exit }' "$WORKFLOW_FILE")"
  expected="$ACCEPTED_ONLY"
  [ "$step" = "Gate distribution with syspolicy_check" ] || expected="$NOT_NOTARY_TEST"
  if [ "$step_if" != "$expected" ]; then
    echo "FAIL: $step must run only for an Accepted build: $step_if"
    exit 1
  fi
done
# The signing job installs no Bun (main #37f07fec trimmed its setup).
if awk '/^  build-sign-notarize-nightly:/ { j=1; next } /^  [A-Za-z0-9_-]+:/ { j=0 } j && /setup-bun@/ { f=1 } END { exit !f }' "$WORKFLOW_FILE"; then
  echo "FAIL: the nightly signing job must not set up Bun"
  exit 1
fi

RELEASE_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/release.yml"
if grep -Eq 'Cloud tunnel|SystemExtensions|tunnel-extension|cmux-cua|Computer Use' "$RELEASE_WORKFLOW_FILE"; then
  echo "FAIL: release still handles the legacy tunnel extension or Computer Use helper"
  exit 1
fi

# A release ships its own commit's cmux-tui tree (pin-cmux-tui.sh
# resolve-exact, cx-urd.9.1); the nightly ships the newest published cmux-tui
# tree and builds the app at that commit (pin-cmux-tui.sh
# resolve-newest-published; tests/test_nightly_cmux_tui_resolve.py).
if ! grep -Fq 'resolved="$(scripts/cmux-next/pin-cmux-tui.sh resolve-exact)"' "$RELEASE_WORKFLOW_FILE" \
    || ! grep -Fq 'cmux_tui_commit="$CMUX_TUI_CLIENT_COMMIT"' "$RELEASE_WORKFLOW_FILE"; then
  echo "FAIL: release.yml must install its own commit's cmux-tui tree (resolve-exact)"
  exit 1
fi
if grep -Fq 'scripts/cmux-next/cmux-tui.pin' "$RELEASE_WORKFLOW_FILE"; then
  echo "FAIL: release.yml must not read the hand pin scripts/cmux-next/cmux-tui.pin"
  exit 1
fi
if ! grep -Fq 'resolved="$(scripts/cmux-next/pin-cmux-tui.sh resolve-newest-published)"' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly.yml must install the newest published cmux-tui tree (resolve-newest-published)"
  exit 1
fi
for workflow in "$WORKFLOW_FILE" "$RELEASE_WORKFLOW_FILE"; do
  if grep -Fq 'git log -1 --format=%H -- cmux-tui' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must not pick the cmux-tui commit with a bare git log: actions/checkout is depth 1 there, so it always answers HEAD"
    exit 1
  fi
  if ! grep -Fq 'https://files.cmux.com/cmux-tui/${cmux_tui_commit}/manifest.json' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must install the immutable cmux-tui manifest"
    exit 1
  fi
  if ! grep -Fq -- '--expected-commit "$cmux_tui_commit"' "$workflow" ||
     ! grep -Fq -- '--require-capability wireguard-hub' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must reject a stale cmux-tui client without WireGuard hub support"
    exit 1
  fi
done

# The commit is resolved in its own job BEFORE the Xcode compile (the app builds
# at the resolved commit: tests/test_nightly_cmux_tui_resolve.py), never in
# build-nightly-app; build-nightly-app installs that one commit before it
# archives the app, and every sign variant requires it before thinning.
if ! awk '
  /^  prepare-nightly-variant-primary:/ { job="prepare-nightly-variant-primary:" }
  /^  [a-zA-Z0-9_-]+:$/ { job=$1 }
  job == "build-nightly-app:" && /resolve-cmux-tui-client-commit\.sh/ { in_app=1 }
  job == "resolve-nightly-cmux-tui-client:" && /^    needs: decide$/ { resolver_needs=1 }
  job == "resolve-nightly-cmux-tui-client:" && /scripts\/cmux-next\/pin-cmux-tui\.sh resolve-newest-published/ { resolver=1 }
  job == "prepare-nightly-variant-primary:" && /^    needs: .*resolve-nightly-cmux-tui-client/ { sign_needs=1 }
  job == "build-nightly-app:" && /^      - name: Bundle the cmux-tui client$/ { install_line=NR }
  job == "build-nightly-app:" && /^      - name: Archive unsigned nightly app$/ { archive_line=NR }
  job == "build-nightly-app:" && /CMUX_TUI_CLIENT_COMMIT: \$\{\{ needs\.resolve-nightly-cmux-tui-client\.outputs\.commit \}\}/ { app_commit=1 }
  job == "prepare-nightly-variant-primary:" && /name: Require the cmux-tui client build-nightly-app bundled$/ { require_line=NR }
  job == "prepare-nightly-variant-primary:" && /^      - name: Thin bundle to the variant architecture$/ { thin_line=NR }
  job == "prepare-nightly-variant-primary:" && /CMUX_TUI_CLIENT_COMMIT: \$\{\{ needs\.resolve-nightly-cmux-tui-client\.outputs\.commit \}\}/ { sign_commit=1 }
  job == "report-nightly-failure:" && /^    needs: .*resolve-nightly-cmux-tui-client/ { reported=1 }
  END { exit !(!in_app && resolver_needs && resolver && sign_needs && sign_commit && app_commit && install_line && archive_line && install_line < archive_line && require_line && thin_line && require_line < thin_line && reported) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly must resolve the cmux-tui commit before the compile, install it in build-nightly-app before archiving, and require it in every sign variant before thinning"
  exit 1
fi

for workflow in "$WORKFLOW_FILE" "$RELEASE_WORKFLOW_FILE"; do
  if grep -Fq 'signing will use the wg-quick fallback' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must not ship without the Network Extension"
    exit 1
  fi
done

# build-nightly-app installs the cmux-tui client and its SSH payloads after its
# own strip, so it must run strip-release-bundle.sh again after that install,
# before it archives the app.
if ! awk '
  /^  [a-zA-Z0-9_-]+:$/ { job=$1 }
  job == "build-nightly-app:" && /\.\/scripts\/install-cmux-tui-client\.sh/ && !install_line { install_line=NR }
  job == "build-nightly-app:" && install_line && /\.\/scripts\/strip-release-bundle\.sh "\$app"/ && !strip_line { strip_line=NR }
  job == "build-nightly-app:" && /^      - name: Archive unsigned nightly app$/ { archive_line=NR }
  END { exit !(install_line && strip_line && archive_line && install_line < strip_line && strip_line < archive_line) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: build-nightly-app must run strip-release-bundle.sh after installing the cmux-tui client and before archiving"
  exit 1
fi

INSTALL_TUI_SCRIPT="$ROOT_DIR/scripts/install-cmux-tui-client.sh"
for expected in '--expected-commit' '--require-capability' 'required cmux-tui capability is missing'; do
  if ! grep -Fq -- "$expected" "$INSTALL_TUI_SCRIPT"; then
    echo "FAIL: cmux-tui installer must enforce $expected"
    exit 1
  fi
done

# Tagged reloads bundle only the same-tree hosted cmux-tui (or the pin, or an
# explicit CMUX_NEXT_TUI_BIN override); any other source fails the reload.
if ! grep -A3 -F 'case "$cmux_next_tui_source" in' "$ROOT_DIR/scripts/reload.sh" |
   grep -Fq -- 'tree-hosted|tree-local-build|pinned-hosted|override)'; then
  echo "FAIL: tagged reloads must reject a cmux-tui that is not the same-tree hosted build"
  exit 1
fi

if grep -Eq 'Smoke launch signed app|Smoke bundled CLI|smoke-launch-macos-app|smoke-signed-app-cli' "$RELEASE_WORKFLOW_FILE"; then
  echo "FAIL: release must contain no app launch or bundled CLI smoke"
  exit 1
fi
if ! grep -Fq './scripts/ci/verify-dmg-artifact.sh "$DMG_RELEASE" stable --require-stapled-app' "$RELEASE_WORKFLOW_FILE" \
   || ! grep -Fq 'verify-diff-sidecar-artifact.sh' "$RELEASE_WORKFLOW_FILE"; then
  echo "FAIL: release must retain static DMG and sidecar protocol verification"
  exit 1
fi

# PR release builds restore the cache nightly warms from main by this prefix.
# Renaming it on either side, or on a key but not its restore-keys, silently
# turns every PR release build or every nightly restore cold.
XCODE_CACHE_PREFIX='xcode-compilation-release-${{ runner.os }}-${{ runner.arch }}-${{ steps.compilation-cache-key.outputs.toolchain }}-'
for cache_workflow in "$WORKFLOW_FILE" "$CI_WORKFLOW_FILE"; do
  if ! grep -qF -- "$XCODE_CACHE_PREFIX" "$cache_workflow" \
    || grep -F 'xcode-compilation-release-' "$cache_workflow" | grep -vqF -- "$XCODE_CACHE_PREFIX"; then
    echo "FAIL: nightly and PR release builds must share one Xcode compilation cache key prefix"
    exit 1
  fi
done

# A warm build leaves a dead CAS generation behind, so the cache directory
# measures two full builds and used to exceed the bound on every warm run.
# Prune it before measuring, then save explicitly on a miss using the bound
# step's verdict instead of rescanning the directory with hashFiles.
if ! awk '
  /^  refresh-compilation-cache:/ { job="refresh"; next }
  /^  build-nightly-app:/ { job="app"; next }
  /^  [a-zA-Z0-9_-]+:/ { job=""; step="" }
  job && /^      - name: Bound Xcode compilation cache size/ { step="bound"; bound[job]=NR; next }
  job && /^      - name: Save Xcode compilation cache/ { step="save"; save[job]=NR; next }
  job && /^      - name:/ { step="" }
  step == "bound" && /^        id: compilation-cache-bound$/ { bound_id[job]=1 }
  step == "bound" && /python3 scripts\/ci\/prune-xcode-compilation-cache\.py "\$cache_path" \\$/ { prune[job]=NR }
  step == "bound" && prune[job] && NR == prune[job] + 1 && /^ +\|\| echo "::warning::Xcode compilation cache pruning failed/ { prune_nonfatal[job]=1 }
  step == "bound" && /cache_kib=\$\(du -sk "\$cache_path"/ { measure[job]=NR }
  step == "bound" && /echo "save=/ && /GITHUB_OUTPUT/ { verdict[job]=1 }
  step == "save" && /uses: (actions\/cache\/save@|\.\/\.github\/actions\/cache-save$)/ { save_action[job]=1 }
  step == "save" && /steps\.compilation-cache-restore\.outputs\.cache-hit != '\''true'\'' && steps\.compilation-cache-bound\.outputs\.save == '\''true'\''$/ { save_gate[job]=1 }
  step == "save" && /hashFiles/ { rescan[job]=1 }
  END {
    n = split("refresh app", jobs, " ")
    for (i = 1; i <= n; i++) {
      j = jobs[i]
      if (!(bound[j] && bound_id[j] && prune[j] && prune_nonfatal[j] && measure[j] && prune[j] < measure[j] && verdict[j] && save[j] && save[j] > bound[j] && save_action[j] && save_gate[j] && !rescan[j])) exit 1
    }
    exit 0
  }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly cache saves must prune dead CAS generations (non-fatally) before measuring the bound, then save explicitly on a miss from the bound step verdict"
  exit 1
fi

if ! grep -Fq 'github.event.inputs.fast == '\''true'\'' && '\''fast'\'' || '\''full'\''' "$WORKFLOW_FILE"; then
  echo "FAIL: fast branch builds must not queue behind a full build on the same branch"
  exit 1
fi

for expected in \
  'if: needs.decide.outputs.fast_build != '\''true'\''' \
  'if: needs.decide.outputs.fast_build == '\''true'\''' \
  'name: cmux-nightly-fast-${{ needs.resolve-nightly-cmux-tui-client.outputs.build_short_sha }}'; do
  if ! grep -Fq "$expected" "$WORKFLOW_FILE"; then
    echo "FAIL: fast build workflow is missing: $expected"
    exit 1
  fi
done

if ! awk '
  /^  report-nightly-failure:/ { job="report"; next }
  /^  close-nightly-failure-issue:/ { job="close"; next }
  /^  [a-zA-Z0-9_-]+:/ { job="" }
  job == "report" && /contains\(needs\.\*\.result, .failure.\)/ { saw_report_gate=1 }
  job == "report" && /issues: write/ { saw_report_perm=1 }
  job == "report" && /\$\{process\.env\.CHANNEL_RELEASE_TAG\}-failure/ { saw_report_label=1 }
  job == "close" && /needs\.publish-nightly\.result == .success./ { saw_close_gate=1 }
  job == "close" && /state: .closed./ { saw_close=1 }
  END { exit !(saw_report_gate && saw_report_perm && saw_report_label && saw_close_gate && saw_close) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: a failing main nightly must open a nightly-failure issue and a successful publish must close it"
  exit 1
fi

if ! grep -Fq "const shouldPublish = !seedOnly && (isTrackRef || isRcRef) && !buildOnly && !fastBuild;" "$WORKFLOW_FILE" \
  || ! grep -Fq "core.setOutput('should_publish', shouldPublish ? 'true' : 'false');" "$WORKFLOW_FILE"; then
  echo "FAIL: nightly decide step must expose should_publish only for main, nightly-next and rc/ refs that are not measurement or fast runs"
  exit 1
fi

if ! awk '
  /^      - name: Upload branch nightly artifacts/ { in_upload=1; next }
  in_upload && /^      - name:/ { in_upload=0 }
  in_upload && /if: needs\.decide\.outputs\.should_publish != '\''true'\''/ { saw_if=1 }
  in_upload && /uses: actions\/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7/ { saw_upload=1 }
  in_upload && /\$\{\{ needs\.decide\.outputs\.dmg_prefix \}\}\*\.dmg/ { saw_arm_artifacts=1 }
  in_upload && /appcast\*\.xml/ { saw_appcasts=1 }
  END { exit !(saw_if && saw_upload && saw_arm_artifacts && saw_appcasts) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: non-main nightly runs must upload every nightly DMG and appcast"
  exit 1
fi

if ! awk '
  /^      - name: Move channel release tag to built commit/ { in_move=1; next }
  in_move && /^      - name:/ { in_move=0 }
  in_move && /if: needs\.decide\.outputs\.should_publish == '\''true'\''/ { saw_move_if=1 }
  in_move && /id: move-channel-release-tag/ { saw_move_id=1 }
  in_move && /continue-on-error: true/ { saw_move_best_effort=1 }
  in_move && /GH_TOKEN: \$\{\{ steps\.release-tag-token\.outputs\.token \}\}/ { saw_app_token=1 }
  in_move && index($0, "GITHUB_TOKEN: ''") { saw_github_token_cleared=1 }
  in_move && /(scripts|PUBLISH_TOOLING)\/ci\/update-release-tag\.py/ { saw_api_update=1 }
  END { exit !(saw_move_if && saw_move_id && saw_move_best_effort && saw_app_token && saw_github_token_cleared && saw_api_update) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: moving the channel release tag must use the scoped app token, remain observable when stale, and use the verified API helper"
  exit 1
fi

if ! awk '
  /^      - name: Mint release tag app token/ { in_token=1; next }
  in_token && /^      - name:/ { in_token=0 }
  in_token && /actions\/create-github-app-token@/ { saw_action=1 }
  in_token && /permission-contents: write/ { saw_contents=1 }
  in_token && /permission-workflows: write/ { saw_workflows=1 }
  /^      - name: Record nightly publication marker outcome/ { in_outcome=1; next }
  in_outcome && /^      - name:/ { in_outcome=0 }
  in_outcome && /id: tag-outcome/ { saw_outcome_id=1 }
  in_outcome && /tag_status=updated/ { saw_updated=1 }
  in_outcome && /tag_status=stale/ { saw_stale=1 }
  in_outcome && /Published, tag marker stale/ { saw_summary=1 }
  in_outcome && /"\$TAG_MOVE_OUTCOME" != "failure"/ { saw_unpublished_branch=1 }
  in_outcome && /tag_status=unpublished/ { saw_unpublished=1 }
  in_outcome && /### Not published/ { saw_unpublished_summary=1 }
  END { exit !(saw_action && saw_contents && saw_workflows && saw_outcome_id && saw_updated && saw_stale && saw_summary && saw_unpublished_branch && saw_unpublished && saw_unpublished_summary) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly tag publication must mint contents/workflows app permissions and record updated/stale/unpublished outcomes (a skipped tag move is never reported as live)"
  exit 1
fi

# Run the outcome step's script: it must say what each publication part did,
# and "Nothing is live" only when the asset upload stopped everything.
outcome_dir="$(mktemp -d)"
outcome_script="$outcome_dir/outcome.sh"
python3 - "$WORKFLOW_FILE" "$outcome_script" <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in workflow["jobs"]["publish-nightly"]["steps"] if s.get("id") == "tag-outcome")
open(sys.argv[2], "w").write(step["run"])
PY
run_outcome() {
  : > "$outcome_dir/out"; : > "$outcome_dir/summary"
  env TAG_MOVE_OUTCOME="$1" ASSETS_OUTCOME="$2" METADATA_OUTCOME="$3" APPCASTS_OUTCOME="$4" NEXT_APPCASTS_OUTCOME="$5" \
    CHANNEL_RELEASE_TAG=nightly-next HEAD_SHA=abc123 GITHUB_OUTPUT="$outcome_dir/out" GITHUB_STEP_SUMMARY="$outcome_dir/summary" \
    bash "$outcome_script"
}
expect_outcome() {
  local want="$1" status="$2"; shift 2
  local got
  got="$(run_outcome "$@")"
  if ! grep -qx "tag_status=$status" "$outcome_dir/out" || ! grep -Fq -- "$want" <<<"$got" \
    || { [ "$status" = unpublished ] && ! grep -Fq -- "$want" "$outcome_dir/summary"; }; then
    echo "FAIL: publication outcome for ($*) must report tag_status=$status and \"$want\", got: $got"
    exit 1
  fi
}
expect_outcome "Nothing is live for abc123 (release assets: failure; release metadata: skipped; appcasts: not uploaded, still serving the previous build; nightly-next tag: not moved)" unpublished skipped failure skipped skipped skipped
expect_outcome "did not complete (release assets: success; release metadata: success; appcasts: failure, may be partly updated;" unpublished skipped success success skipped failure
expect_outcome "Published assets, release metadata, and appcasts are live" stale failure success success skipped success
if run_outcome skipped failure skipped skipped skipped | grep -Fq "are live"; then
  echo "FAIL: a failed asset upload must never be reported as live"
  exit 1
fi
rm -rf "$outcome_dir"

for expected in \
  'cmux-published-sha:' \
  'nightly-publication-marker.py' \
  'release metadata already records the exact' \
  'published, tag marker stale' \
  "needs.publish-nightly.outputs.tag_status == 'stale'" \
  "needs.publish-nightly.outputs.tag_status == 'updated'"; do
  if ! grep -Fqi "$expected" "$WORKFLOW_FILE"; then
    echo "FAIL: nightly publication recovery contract is missing: $expected"
    exit 1
  fi
done

if ! awk '
  /^      - name: Publish nightly release assets/ { in_publish=1; next }
  in_publish && /^      - name:/ { in_publish=0 }
  in_publish && /if: needs\.decide\.outputs\.should_publish == '\''true'\''/ { saw_publish_if=1 }
  in_publish && /publish-release-assets\.py/ { saw_publisher=1 }
  # Main publishes every variant, four aliases and the four feeds decide lists;
  # nightly-next publishes arm64 only (tests/test_nightly_next_arm64_only.py).
  in_publish && /variants=\(arm64 x86_64 universal\)/ { saw_all_variants=1 }
  in_publish && /--immutable .*CHANNEL_DMG_PREFIX.*-\$\{variant\}-\$\{NIGHTLY_BUILD\}\.dmg/ { saw_immutable_variants=1 }
  in_publish && /aliases=\(.*-arm64\.dmg.*-x86_64\.dmg.*-universal\.dmg" "\$\{CHANNEL_DMG_PREFIX\}\.dmg"\)/ { saw_four_aliases=1 }
  in_publish && /for feed in \$NIGHTLY_FEEDS/ { saw_feeds=1 }
  END { exit !(saw_publish_if && saw_publisher && saw_all_variants && saw_immutable_variants && saw_four_aliases && saw_feeds) }
' "$WORKFLOW_FILE" || ! grep -Fq ": ['appcast-arm64.xml', 'appcast-x86_64.xml', 'appcast-universal.xml', 'appcast.xml'];" "$WORKFLOW_FILE"; then
  echo "FAIL: nightly publication must verify every architecture and publish all aliases before the four feeds"
  exit 1
fi

# A build-only measurement run is the only safe way to time the nightly build
# job from a branch: a full branch dispatch still signs and notarizes under the
# release identity. build_only must stop at the unsigned universal build, so it
# never reaches the helper, signing, notarization, dSYM upload, or publication,
# and cold_cache (skip the compilation cache restore) is only honoured there.
for expected in \
  'description: Measure the unsigned universal build only. Never builds the helper, signs, notarizes, uploads dSYMs, or publishes.' \
  'description: Skip the Xcode compilation cache restore so the measurement run is a cache miss. Only honoured with build_only.' \
  "const buildOnly = process.env.BUILD_ONLY === 'true';" \
  "const coldCache = buildOnly && process.env.COLD_CACHE === 'true';" \
  "core.setOutput('build_only', buildOnly ? 'true' : 'false');" \
  "core.setOutput('cold_cache', coldCache ? 'true' : 'false');" \
  'build_only: ${{ steps.decide.outputs.build_only }}' \
  'cold_cache: ${{ steps.decide.outputs.cold_cache }}'; do
  if ! grep -Fq "$expected" "$WORKFLOW_FILE"; then
    echo "FAIL: build-only measurement lane is missing: $expected"
    exit 1
  fi
done

# Each job's complete job-level `if:` is matched verbatim, so the build_only
# exclusion can only ever be a conjunctive clause: an `||` around it would run
# helper, signing, or publish work during a measurement dispatch. The resolver
# runs for every app build (it picks the commit the app builds at), so it
# matches build-nightly-app; its resolve step skips build_only.
job_if() {
  awk -v job="$1" '
    $0 ~ "^  " job ":( |$)" { in_job=1; next }
    in_job && /^  [a-zA-Z0-9_-]+:$/ { in_job=0 }
    in_job && /^    if: / { print; exit }
  ' "$WORKFLOW_FILE"
}
PUBLISH_SCHEDULE="(github.event_name != 'schedule' || github.event.schedule == '47 8 * * *')"
# A resolved build commit that is already published builds nothing.
NOT_PUBLISHED="needs.resolve-nightly-cmux-tui-client.outputs.already_published != 'true'"
# A nightly-next continuation run (nightly_next_continue_only) builds nothing of its own.
NOT_CONTINUE="needs.decide.outputs.continue_only != 'true'"
# A nightly-next push that a newer push replaced builds nothing (one build slot, #21917).
NOT_SUPERSEDED="needs.resolve-nightly-cmux-tui-client.outputs.superseded != 'true'"
if [ "$(job_if build-nightly-app)" != "    if: needs.decide.outputs.should_build == 'true' && $PUBLISH_SCHEDULE && $NOT_PUBLISHED && $NOT_SUPERSEDED && $NOT_CONTINUE" ] \
  || [ "$(job_if build-nightly-ghostty-cli-helper)" != "    if: needs.decide.outputs.should_build == 'true' && $PUBLISH_SCHEDULE && needs.decide.outputs.build_only != 'true' && $NOT_PUBLISHED && $NOT_SUPERSEDED && $NOT_CONTINUE" ] \
  || [ "$(job_if build-sign-notarize-nightly)" != "    if: needs.decide.outputs.should_build == 'true' && $PUBLISH_SCHEDULE && needs.decide.outputs.build_only != 'true' && $NOT_PUBLISHED && $NOT_SUPERSEDED && $NOT_CONTINUE" ] \
  || [ "$(job_if prepare-nightly-variant-primary)" != "$(job_if build-sign-notarize-nightly)" ] \
  || [ "$(job_if resolve-nightly-cmux-tui-client) && $NOT_PUBLISHED && $NOT_SUPERSEDED && $NOT_CONTINUE" != "$(job_if build-nightly-app)" ] \
  || [ "$(job_if publish-nightly)" != "    if: \"!cancelled() && needs.decide.result == 'success' && needs.decide.outputs.should_build == 'true' && needs.decide.outputs.fast_build != 'true' && needs.decide.outputs.build_only != 'true' && $PUBLISH_SCHEDULE && $NOT_PUBLISHED && needs.decide.outputs.no_publish != 'true' && ((needs.build-sign-notarize-nightly.result == 'success' && needs.build-sign-notarize-nightly.outputs.notary_pending != 'true' && needs.verify-signed-nightly.result == 'success' && needs.verify-final-dmg-nightly.result == 'success') || (needs.recover-nightly-next-notarization.outputs.accepted == 'true' && needs.verify-recovered-nightly-next.result == 'success'))\"" ]; then
  echo "FAIL: build_only must be a conjunctive exclusion on the helper, signing, and publication jobs, and must not gate the unsigned app build"
  exit 1
fi

# A measurement run always builds the production universal workload: it must
# not depend on the nightly tag (a build-only dispatch on main would otherwise
# skip when the tag already matches HEAD) and must ignore the fast arm64 path.
# Match the expression, not its declaration keyword, so that rebinding
# shouldBuild later in `decide` does not read as a change to this contract.
for expected in \
  "const alreadyPublished = !continueOnly && !buildOnly && !forceBuild && (isTrackRef || isRcRef) && publishedSha === headSha;" \
  "shouldBuild = !seedOnly && !alreadyPublished && (buildOnly || !isTrackRef || forceBuild || nightlySha !== headSha);" \
  "fastBuild = !buildOnly && process.env.FAST_BUILD === 'true';"; do
  if ! grep -Fq "$expected" "$WORKFLOW_FILE"; then
    echo "FAIL: build_only must always build the universal app: $expected"
    exit 1
  fi
done

if ! awk '
  /^  build-nightly-app:/ { job="app"; next }
  /^  [a-zA-Z0-9_-]+:/ { job=""; step="" }
  job == "app" && /^      - name: Restore Xcode compilation cache/ { step="restore"; next }
  job == "app" && /^      - name: Upload dSYMs to Sentry/ { step="dsym"; next }
  job == "app" && /^      - name: Archive unsigned nightly app/ { step="archive"; next }
  job == "app" && /^      - name: Upload unsigned nightly app/ { step="upload"; next }
  job == "app" && /^      - name:/ { step="" }
  step == "restore" && /needs\.decide\.outputs\.cold_cache != '\''true'\''/ { saw_cold_gate=1 }
  step == "dsym" && /needs\.decide\.outputs\.build_only != '\''true'\''/ { saw_dsym_gate=1 }
  step == "archive" && /needs\.decide\.outputs\.build_only != '\''true'\''/ { saw_archive_gate=1 }
  step == "upload" && /needs\.decide\.outputs\.build_only != '\''true'\''/ { saw_upload_gate=1 }
  END { exit !(saw_cold_gate && saw_dsym_gate && saw_archive_gate && saw_upload_gate) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: build-only must allow a cold cache and skip dSYMs plus unused app archive/upload"
  exit 1
fi

if ! grep -Fq "github.event.inputs.build_only == 'true' && format('nightly-measure-{0}', github.run_id)" "$WORKFLOW_FILE"; then
  echo "FAIL: build-only measurement runs must not share a concurrency group with publishing nightly runs (a newer queued run cancels the pending one)"
  exit 1
fi

# nightly-next keeps its own concurrency group. A group shared with main let
# every main push replace the pending nightly-next run (run 37579667979 was
# cancelled before any job by main push run 37580645859), so the lower-frequency
# track starved. The cross-feed build floor (nightly_version.py check-build)
# still refuses a nightly-next build that is not above main's feed; that race
# needs a main run to publish inside one nightly-next build and fails loudly.
if grep -Fq "github.ref_name == 'nightly-next') && 'nightly-shared'" "$WORKFLOW_FILE"; then
  echo "FAIL: nightly-next must not share main's concurrency group (main pushes replace its pending run)"
  exit 1
fi
if ! grep -Fq 'python3 scripts/ci/nightly_version.py check-build --build "$build" "${feeds[@]}"' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly-next must keep the cross-feed build floor check"
  exit 1
fi

# Every nightly lane must let an in-flight build finish. GitHub still keeps one
# pending run per group, so a newer push replaces only an older queued run.
if ! grep -Fq "github.event_name == 'schedule' && github.event.schedule == '17 */6 * * *' && 'cache-seed-scheduled'" "$WORKFLOW_FILE"; then
  echo "FAIL: the six-hour cache warmup must have its own replaceable concurrency group"
  exit 1
fi
if ! grep -Fq "inputs.seed_only && 'cache-seed-manual'" "$WORKFLOW_FILE"; then
  echo "FAIL: manually dispatched cache seeds must have a separate concurrency group"
  exit 1
fi
if grep -Fq "&& 'cache-seed'" "$WORKFLOW_FILE"; then
  echo "FAIL: scheduled and manual cache seeds must not share the legacy cache-seed group"
  exit 1
fi
if ! grep -Fq "cancel-in-progress: false" "$WORKFLOW_FILE"; then
  echo "FAIL: nightly runs must never cancel an in-flight build"
  exit 1
fi
if grep -Eq "cancel-in-progress: \$\{\{" "$WORKFLOW_FILE"; then
  echo "FAIL: nightly cancellation must be a literal false policy, not an event expression"
  exit 1
fi

# An oversize cache silently freezes the nightly cache at the last saved entry:
# every later build restores that entry, exceeds the bound again, and never
# saves. Surface the skip as a workflow warning so the freeze is visible.
for cache_workflow in "$WORKFLOW_FILE"; do
  if grep -Fq 'echo "Xcode compilation cache exceeds 5 GiB; skipping cache save"' "$cache_workflow" \
    || ! grep -Fq 'echo "::warning::Xcode compilation cache exceeds 5 GiB; skipping cache save"' "$cache_workflow"; then
    echo "FAIL: $(basename "$cache_workflow") must report an oversize compilation cache as a workflow warning"
    exit 1
  fi
done

# cx-x7hwx: the cmux NIGHTLY-identity old feed follows the newest cmux NEXT
# build, whichever run published it. #20518 hands a build still in Apple's
# queue to recovery, so a later run (or a continue-only run) publishes it; the
# legacy job must start then too, and must not start for a build the old feed
# already has. A cmux NIGHTLY-identity submission still in Apple's queue is
# continued (never resubmitted) until it is resolved or 6 hours old.
legacy_dir="$(mktemp -d)"
trap 'rm -rf "$legacy_dir" "$WORKFLOW_FILE"' EXIT
legacy_feed() {  # <file> <build>...
  local file="$1"; shift
  {
    echo '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>'
    local build
    for build in "$@"; do
      echo "<item><sparkle:version>$build</sparkle:version><enclosure url=\"https://github.com/manaflow-ai/cmux/releases/download/nightly-next/cmux-nightly-next-macos-arm64-$build.dmg\" type=\"application/octet-stream\"/></item>"
    done
    echo '</channel></rss>'
  } > "$file"
}
legacy_target() {  # [extra args]; prints "action build pending_run"
  python3 "$ROOT_DIR/scripts/ci/nightly-next-legacy-target.py" "$legacy_dir/next.xml" "$legacy_dir/old.xml" cmux-nightly-next-macos-arm64- "$@" \
    | awk -F= '{v[$1]=$2} END {printf "%s %s %s", v["action"], v["build"], v["pending_run"]}'
}
legacy_expect() {  # <expected "action build pending_run"> <message> [extra args]
  local expected="$1" message="$2"; shift 2
  local actual
  actual="$(legacy_target "$@")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $message (expected '$expected', got '$actual')"
    exit 1
  fi
}
now=1800000000
pending_meta() {  # <build> <submitted epoch>
  printf '{"build": "%s", "submission_id": "62484bfc-d2e2-4e80-89d9-4a7a927490ce", "submitted_epoch": %s}\n' "$1" "$2" > "$legacy_dir/pending.json"
}
# A recovered build (published by a later run) is newer than the old feed: copy it.
legacy_feed "$legacy_dir/next.xml" 3851000000001 3850073942601
legacy_feed "$legacy_dir/old.xml" 3821558930001
legacy_expect "new 3851000000001 " "a cmux NEXT build newer than the old feed (published by recovery) must start the cmux NIGHTLY-identity job"
# The old feed already has it, or a newer one: nothing to do.
legacy_feed "$legacy_dir/old.xml" 3851000000001
legacy_expect "none  " "a cmux NEXT build the old feed already has must not start the cmux NIGHTLY-identity job"
legacy_feed "$legacy_dir/old.xml" 3852000000001
legacy_expect "none  " "a cmux NEXT build older than the old feed must not start the cmux NIGHTLY-identity job"
# A pending submission still in Apple's queue is continued, even when a newer
# cmux NEXT build exists, while it is younger than 6 hours.
legacy_feed "$legacy_dir/old.xml" 3821558930001
pending_meta 3850073942601 $((now - 3 * 3600))
legacy_expect "continue 3850073942601 38566549515" "a pending cmux NIGHTLY-identity submission under 6 h must be continued, not replaced" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38566549515 --now "$now"
# After 6 hours the newest cmux NEXT build gets a new submission.
pending_meta 3850073942601 $((now - 7 * 3600))
legacy_expect "new 3851000000001 " "a pending submission older than 6 h must give way to the newest cmux NEXT build" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38566549515 --now "$now"
# Apple can hold a submission for many hours: with no newer cmux NEXT build,
# the pending submission is continued up to 48 hours, never resubmitted.
legacy_feed "$legacy_dir/next.xml" 3850073942601
pending_meta 3850073942601 $((now - 7 * 3600))
legacy_expect "continue 3850073942601 38566549515" "a pending submission of the newest cmux NEXT build at 7 h must be continued, not resubmitted" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38566549515 --now "$now"
pending_meta 3850073942601 $((now - 49 * 3600))
legacy_expect "new 3850073942601 " "a pending submission older than 48 h must give way to a new submission" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38566549515 --now "$now"
legacy_feed "$legacy_dir/next.xml" 3851000000001 3850073942601
# Once the old feed has the pending build, the pending record is stale.
legacy_feed "$legacy_dir/old.xml" 3850073942601
pending_meta 3850073942601 $((now - 3600))
legacy_expect "new 3851000000001 " "a pending build the old feed already has must not be continued" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38566549515 --now "$now"
# The enclosure must be the exact published cmux NEXT DMG of that build.
sed 's#arm64-3851000000001.dmg#arm64-1.dmg#' "$legacy_dir/next.xml" > "$legacy_dir/bad.xml" && mv "$legacy_dir/bad.xml" "$legacy_dir/next.xml"
legacy_feed "$legacy_dir/old.xml" 3821558930001
if python3 "$ROOT_DIR/scripts/ci/nightly-next-legacy-target.py" "$legacy_dir/next.xml" "$legacy_dir/old.xml" cmux-nightly-next-macos-arm64- >/dev/null 2>&1; then
  echo "FAIL: a cmux NEXT item whose enclosure is not its own DMG must stop the cmux NIGHTLY-identity job"
  exit 1
fi
# After an attempt (hq-a3, 2026-10-15): an Accepted submission is never retired
# by a later failure; its bundle is kept and marked accepted, and the failure
# counts. A submission Apple refused is retired and counted. A submission still
# in Apple's queue, or one Apple has not answered about, is kept and not counted.
legacy_resolve() {  # <expected "retire mark_accepted real"> <message> <args...>
  local expected="$1" message="$2"; shift 2
  local actual
  actual="$(python3 "$ROOT_DIR/scripts/ci/nightly-next-legacy-resolve.py" "$@" \
    | awk -F= '{v[$1]=$2} END {printf "%s %s %s", v["retire"], v["mark_accepted"], v["real"]}')"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $message (expected '$expected', got '$actual')"
    exit 1
  fi
}
legacy_resolve "false true true" "an Accepted continuation whose later check failed must be kept, marked accepted and counted" \
  --action continue --pending false --notarize failure --published false --apple accepted
legacy_resolve "false true true" "an Accepted continuation that failed only to publish must be kept, marked accepted and counted" \
  --action continue --pending false --notarize success --published false --apple accepted
legacy_resolve "true false false" "a published continuation must be retired" \
  --action continue --pending false --notarize success --published true --apple accepted
legacy_resolve "true false true" "a continuation Apple refused must be retired and counted" \
  --action continue --pending false --notarize failure --published false --apple refused
legacy_resolve "false false false" "a continuation that failed before Apple answered must be kept and not counted" \
  --action continue --pending false --notarize failure --published false --apple unknown
legacy_resolve "false false false" "a submission still in Apple's queue must be kept and never counted (even if keeping it failed)" \
  --action new --pending true --notarize success --published false --apple unknown
legacy_resolve "false false true" "a failed new attempt must count" \
  --action new --pending false --notarize failure --published false --apple unknown
# Did the attempt fail (cx-vws1x)? It drives the failure report and the
# publish job's red result after the sign, verify and publish split.
legacy_attempt() {  # <expected true|false> <message> <args...>
  local expected="$1" message="$2"; shift 2
  local actual
  actual="$(python3 "$ROOT_DIR/scripts/ci/nightly-next-legacy-attempt.py" "$@" | sed -n 's/^failed=//p')"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $message (expected failed=$expected, got '$actual')"
    exit 1
  fi
}
legacy_attempt false "a published attempt must not fail" \
  --sign-result success --sign-skip false --signed-ok true --pending false --published true --job-ok true
legacy_attempt false "a submission still in Apple's queue must not fail" \
  --sign-result success --sign-skip false --signed-ok true --pending true --published false --job-ok true
legacy_attempt true "a final build whose smoke, digest check or upload failed must fail" \
  --sign-result success --sign-skip false --signed-ok true --pending false --published false --job-ok true
legacy_attempt true "a failed signing job must fail" \
  --sign-result failure --sign-skip false --signed-ok false --pending false --published false --job-ok true
legacy_attempt true "a signing job that failed before its order check must fail" \
  --sign-result failure --sign-skip "" --signed-ok "" --pending "" --published false --job-ok true
legacy_attempt true "a pending submission that could not be kept must fail (resolve.py does not count it)" \
  --sign-result failure --sign-skip false --signed-ok false --pending true --published false --job-ok true
legacy_attempt false "a signing job cancelled by a newer run must not fail" \
  --sign-result cancelled --sign-skip "" --signed-ok "" --pending "" --published false --job-ok true
legacy_attempt false "a signing job that never ran must not fail" \
  --sign-result skipped --sign-skip "" --signed-ok "" --pending "" --published false --job-ok true
legacy_attempt false "a build the old feed already has must not fail" \
  --sign-result success --sign-skip true --signed-ok true --pending "" --published false --job-ok true
legacy_attempt true "a failed step of the publish job must fail" \
  --sign-result success --sign-skip false --signed-ok true --pending false --published true --job-ok false
# An accepted bundle is continued with no time limit and its build is never
# submitted again; two counted failures stop that build, not a newer one.
legacy_feed "$legacy_dir/next.xml" 3850073942601
legacy_feed "$legacy_dir/old.xml" 3821558930001
printf '{"build": "3850073942601", "submission_id": "00b3d8f2-f8d6-48e5-a793-f4cd6c0cddb4", "submitted_epoch": %s, "accepted": true, "bundle_run": "38609024986"}\n' $((now - 60 * 3600)) > "$legacy_dir/pending.json"
legacy_expect "continue 3850073942601 38669958906" "an accepted submission at 60 h must be continued, never resubmitted" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38669958906 --now "$now"
bundle_run="$(python3 "$ROOT_DIR/scripts/ci/nightly-next-legacy-target.py" "$legacy_dir/next.xml" "$legacy_dir/old.xml" cmux-nightly-next-macos-arm64- \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38669958906 --now "$now" | sed -n 's/^bundle_run=//p')"
if [ "$bundle_run" != 38609024986 ]; then
  echo "FAIL: an accepted submission must be continued from the run that holds its bundle (got '$bundle_run')"
  exit 1
fi
printf 'Build 3850073942601 failed: one\nBuild 3850073942601 failed: two\n' > "$legacy_dir/failures.txt"
legacy_expect "none  " "an accepted build with 2 counted failures must be neither continued nor submitted again" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38669958906 --now "$now" --failure-log "$legacy_dir/failures.txt"
legacy_feed "$legacy_dir/next.xml" 3851000000001 3850073942601
legacy_expect "new 3851000000001 " "a newer cmux NEXT build must still be submitted after an older build stopped" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38669958906 --now "$now" --failure-log "$legacy_dir/failures.txt"
printf 'Build 3851000000001 failed: one\nBuild 3851000000001 failed: two\n' > "$legacy_dir/failures.txt"
legacy_expect "none  " "a build with 2 counted failures must not be submitted again" \
  --failure-log "$legacy_dir/failures.txt"
legacy_feed "$legacy_dir/next.xml" 3851000000001 3850073942601
# A pending metadata artifact is retired only when its run confirms the bundle
# is gone; an API error (rate limit, 5xx, timeout) keeps it.
fake_gh_dir="$legacy_dir/fakegh"
mkdir -p "$fake_gh_dir"
cat > "$fake_gh_dir/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"-X DELETE"*)
    [ "${FAKE_GH_DELETE:-ok}" = error ] && { echo "HTTP 503" >&2; exit 1; }
    echo "DELETE $*" >> "$FAKE_GH_LOG"; exit 0 ;;
  *pending-bundle*)
    case "$FAKE_GH_BUNDLES" in error) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;; *) echo "$FAKE_GH_BUNDLES"; exit 0 ;; esac ;;
  *pending-meta*)
    [ "${FAKE_GH_META:-ok}" = error ] && { echo "HTTP 403: rate limit exceeded" >&2; exit 1; }
    echo 4242; exit 0 ;;
esac
exit 1
GH
chmod +x "$fake_gh_dir/gh"
orphan() {  # <bundles: error|0|1> [meta: ok|error] [delete: ok|error] -> prints the script's verdict
  : > "$legacy_dir/gh.log"
  PATH="$fake_gh_dir:$PATH" FAKE_GH_LOG="$legacy_dir/gh.log" FAKE_GH_BUNDLES="$1" FAKE_GH_META="${2:-ok}" FAKE_GH_DELETE="${3:-ok}" \
    bash "$ROOT_DIR/scripts/ci/nightly-next-legacy-orphan-meta.sh" manaflow-ai/cmux 38566549515
}
if [ "$(orphan error | cut -c1-5)" != kept: ] || [ -s "$legacy_dir/gh.log" ]; then
  echo "FAIL: an API error while checking the bundle must keep the pending metadata"
  exit 1
fi
if [ "$(orphan 1 | cut -c1-5)" != kept: ] || [ -s "$legacy_dir/gh.log" ]; then
  echo "FAIL: a pending metadata artifact whose bundle exists must be kept"
  exit 1
fi
if [ "$(orphan 0 error | cut -c1-5)" != kept: ] || [ -s "$legacy_dir/gh.log" ]; then
  echo "FAIL: an API error while listing the pending metadata must keep it"
  exit 1
fi
if [ "$(orphan 0 ok error | cut -c1-5)" != kept: ]; then
  echo "FAIL: a failed delete of the pending metadata must report it as kept"
  exit 1
fi
if [ "$(orphan 0)" != retired ] || ! grep -q 'artifacts/4242' "$legacy_dir/gh.log"; then
  echo "FAIL: a pending metadata artifact whose bundle is confirmed gone must be retired"
  exit 1
fi
# The failure issue is found with GitHub search and an exact title match, not a
# one-page listing of open issues (it may be past the first 100 open issues
# and pull requests); a failed search is an error, never "no issue".
search_gh_dir="$legacy_dir/searchgh"
mkdir -p "$search_gh_dir"
cat > "$search_gh_dir/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *search/issues*)
    [ "$FAKE_SEARCH" = error ] && { echo "HTTP 403: rate limit" >&2; exit 1; }
    printf '%b' "$FAKE_SEARCH"; exit 0 ;;
  *"issues?state=open"*) echo "one-page listing used" >&2; exit 3 ;;
esac
exit 1
GH
chmod +x "$search_gh_dir/gh"
failure_issue() {  # <search rows> -> number (exit code kept)
  PATH="$search_gh_dir:$PATH" FAKE_SEARCH="$1" bash "$ROOT_DIR/scripts/ci/nightly-next-legacy-failure-issue.sh" manaflow-ai/cmux
}
issue_title="cmux NIGHTLY-identity publication failed (nightly.yml publish-nightly-identity-legacy)"
if [ "$(failure_issue "20001\t$issue_title (old)\n20668\t$issue_title\n")" != 20668 ]; then
  echo "FAIL: the failure issue must be found by search with an exact title match"
  exit 1
fi
if [ -n "$(failure_issue "20001\tsomething else\n")" ]; then
  echo "FAIL: no exact title match must give no failure issue"
  exit 1
fi
if failure_issue error >/dev/null 2>&1; then
  echo "FAIL: a failed issue search must be an error, not 'no failure issue'"
  exit 1
fi
if grep -Fq 'issues?state=open&per_page=100' "$WORKFLOW_FILE" || grep -Fq 'listForRepo({ ...context.repo, state' "$WORKFLOW_FILE"; then
  echo "FAIL: the cmux NIGHTLY-identity jobs must find the failure issue by search, not a one-page listing"
  exit 1
fi
# A cmux NEXT build is copied only when every commit in
# NIGHTLY_LEGACY_REQUIRED_COMMITS is in its commit (2026-10-15: builds with
# 79dbcd0baf025 open a new daemon session; the adopt fix must ship with them).
# The build's commit is the head of its nightly-next run; any error fails closed.
req_gh_dir="$legacy_dir/reqgh"
mkdir -p "$req_gh_dir"
cat > "$req_gh_dir/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *actions/runs/*)
    [ "$FAKE_RUN" = error ] && { echo "HTTP 404" >&2; exit 1; }
    echo "$FAKE_RUN"; exit 0 ;;
  *compare/*)
    [ "$FAKE_COMPARE" = error ] && { echo "HTTP 502" >&2; exit 1; }
    echo "$FAKE_COMPARE"; exit 0 ;;
esac
exit 1
GH
chmod +x "$req_gh_dir/gh"
build_sha=692a32616bd6324ca205b90d7b673ee6d32cdce9
adopt_fix=1111111111111111111111111111111111111111
requirement() {  # <run answer> <compare answer> [required...] -> "exit:first word"
  local run="$1" compare="$2"; shift 2
  local out code
  out="$(PATH="$req_gh_dir:$PATH" FAKE_RUN="$run" FAKE_COMPARE="$compare" NIGHTLY_LEGACY_GIT_URL="" \
    bash "$ROOT_DIR/scripts/ci/nightly-next-legacy-requirement.sh" manaflow-ai/cmux 3850073942601 "$@")"
  code=$?
  printf '%s:%s' "$code" "${out%% *}"
}
good_run="$build_sha nightly-next .github/workflows/nightly.yml"
for case in \
  "0:ok|$good_run|ahead|$adopt_fix|a build that contains the required commit must be allowed" \
  "0:ok|$good_run|identical|$adopt_fix|a build at the required commit must be allowed" \
  "3:missing|$good_run|behind|$adopt_fix|a build that lacks the required commit must be refused" \
  "3:missing|$good_run|diverged|$adopt_fix|a build on another line than the required commit must be refused" \
  "1:error:|$good_run|error|$adopt_fix|a failed ancestry check must fail closed" \
  "1:error:|error|ahead|$adopt_fix|an unreadable build run must fail closed" \
  "1:error:|$build_sha main .github/workflows/nightly.yml|ahead|$adopt_fix|a build from another branch must fail closed" \
  "0:ok|$good_run|behind||no required commit means no requirement"; do
  IFS='|' read -r expected run compare required message <<<"$case"
  # shellcheck disable=SC2086 # an empty required list passes no argument
  actual="$(requirement "$run" "$compare" $required)"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $message (expected '$expected', got '$actual')"
    exit 1
  fi
done
# The build's commit comes from its signed release notes first (the app can be
# built at an older commit than its run's head); the run head is the fallback.
notes_sha=2222222222222222222222222222222222222222
mkdir -p "$legacy_dir/notes"
printf '{"build": "3850073942601", "head": "%s"}\n' "$notes_sha" > "$legacy_dir/notes/3850073942601.json"
notes_out="$(PATH="$req_gh_dir:$PATH" FAKE_RUN="$good_run" FAKE_COMPARE=ahead NOTES_BASE="file://$legacy_dir/notes" \
  NIGHTLY_LEGACY_GIT_URL="" bash "$ROOT_DIR/scripts/ci/nightly-next-legacy-requirement.sh" manaflow-ai/cmux 3850073942601 "$adopt_fix")"
if [ "$notes_out" != "ok $notes_sha" ]; then
  echo "FAIL: the build commit must come from the build's release notes when they exist (got '$notes_out')"
  exit 1
fi
# Ancestry comes from git first (GitHub's compare refuses big diffs under load, run
# 40340830337); the compare API answers only when git cannot. A local repository:
# base -> adopt -> build on one line, side on another.
anc_repo="$legacy_dir/ancestry"
git init -q "$anc_repo"
git -C "$anc_repo" config uploadpack.allowAnySHA1InWant true
git -C "$anc_repo" config uploadpack.allowFilter true
anc_commit() { git -C "$anc_repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1" && git -C "$anc_repo" rev-parse HEAD; }
anc_base="$(anc_commit base)"
anc_adopt="$(anc_commit adopt)"
anc_build="$(anc_commit build)"
git -C "$anc_repo" checkout -q --detach "$anc_base"
anc_side="$(anc_commit side)"
ancestry() {  # <required> <compare answer> -> "exit:first word"
  local out code
  out="$(PATH="$req_gh_dir:$PATH" FAKE_RUN="$anc_build nightly-next .github/workflows/nightly.yml" FAKE_COMPARE="$2" \
    NIGHTLY_LEGACY_GIT_URL="file://$anc_repo" \
    bash "$ROOT_DIR/scripts/ci/nightly-next-legacy-requirement.sh" manaflow-ai/cmux 3850073942601 "$1")"
  code=$?
  printf '%s:%s' "$code" "${out%% *}"
}
for case in \
  "0:ok|$anc_adopt|error|a build that contains the required commit is allowed from git, with the compare API down" \
  "0:ok|$anc_build|error|a build at the required commit is allowed" \
  "3:missing|$anc_side|ahead|a build on another line is refused from git, whatever the compare API says" \
  "0:ok|3333333333333333333333333333333333333333|ahead|a commit git cannot fetch falls back to the compare API" \
  "1:error:|3333333333333333333333333333333333333333|error|git and the compare API both failing fails closed"; do
  IFS='|' read -r expected required compare message <<<"$case"
  actual="$(ancestry "$required" "$compare")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $message (expected '$expected', got '$actual')"
    exit 1
  fi
done
# --commit: the macOS job passes the app's own commit; no run or notes are read.
commit_check() {  # <build sha> <required> -> "exit:first word"
  local out code
  out="$(PATH="$req_gh_dir:$PATH" FAKE_RUN=error FAKE_COMPARE=error NIGHTLY_LEGACY_GIT_URL="file://$anc_repo" \
    bash "$ROOT_DIR/scripts/ci/nightly-next-legacy-requirement.sh" --commit manaflow-ai/cmux "$1" "$2")"
  code=$?
  printf '%s:%s' "$code" "${out%% *}"
}
[ "$(commit_check "$anc_build" "$anc_adopt")" = "0:ok" ] || { echo "FAIL: --commit must check the given commit"; exit 1; }
[ "$(commit_check "$anc_side" "$anc_adopt")" = "3:missing" ] || { echo "FAIL: --commit must refuse a commit that lacks the required one"; exit 1; }
short_rc=0
PATH="$req_gh_dir:$PATH" bash "$ROOT_DIR/scripts/ci/nightly-next-legacy-requirement.sh" --commit manaflow-ai/cmux abc >/dev/null 2>&1 || short_rc=$?
[ "$short_rc" -eq 2 ] || { echo "FAIL: --commit needs a full SHA"; exit 1; }
# A stalled fetch is bounded and falls back to the compare API.
stall_dir="$legacy_dir/stallgit"
mkdir -p "$stall_dir"
printf '#!/usr/bin/env bash\ncase "$*" in *fetch*) sleep 30 ;; esac\nexec /usr/bin/git "$@"\n' > "$stall_dir/git"
chmod +x "$stall_dir/git"
stall_start=$SECONDS
stall_out="$(PATH="$stall_dir:$req_gh_dir:$PATH" FAKE_RUN=error FAKE_COMPARE=ahead NIGHTLY_LEGACY_GIT_URL="file://$anc_repo" \
  NIGHTLY_LEGACY_GIT_SECONDS=2 bash "$ROOT_DIR/scripts/ci/nightly-next-legacy-requirement.sh" --commit manaflow-ai/cmux "$anc_side" "$anc_adopt")"
if [ "${stall_out%% *}" != ok ] || [ $((SECONDS - stall_start)) -ge 20 ]; then
  echo "FAIL: a stalled git fetch must be cut off and fall back to the compare API (got '$stall_out')"
  exit 1
fi
# The macOS job checks the app's commit through the script, not the compare API alone.
if ! grep -Fq 'nightly-next-legacy-requirement.sh --commit "$GITHUB_REPOSITORY" "$sha" $REQUIRED' "$WORKFLOW_FILE" \
  || grep -Fq 'compare/$required...$sha' "$WORKFLOW_FILE"; then
  echo "FAIL: the cmux NIGHTLY-identity macOS job must check required commits through nightly-next-legacy-requirement.sh --commit"
  exit 1
fi
# The macOS job's refusal of an app that lacks a required commit is never
# counted, and a continued submission of that build is retired.
legacy_resolve "true false false" "a continued submission refused by the requirement must be retired and not counted" \
  --action continue --pending false --notarize skipped --published false --apple unknown --requirement-refused true
legacy_resolve "false false false" "a new attempt refused by the requirement must not be counted" \
  --action new --pending false --notarize skipped --published false --apple unknown --requirement-refused true
# A refused build is neither continued nor submitted; a newer build is checked next.
legacy_feed "$legacy_dir/next.xml" 3865928435701 3850073942601
legacy_feed "$legacy_dir/old.xml" 3821558930001
pending_meta 3850073942601 $((now - 3600))
legacy_expect "new 3865928435701 " "a pending submission of a refused build must not be continued" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38677509707 --now "$now" --refuse-build 3850073942601
legacy_expect "none  " "refused builds must be neither continued nor submitted" \
  --pending-meta "$legacy_dir/pending.json" --pending-run 38677509707 --now "$now" --refuse-build 3850073942601 --refuse-build 3865928435701
legacy_feed "$legacy_dir/next.xml" 3851000000001 3850073942601
# Wiring: the macOS job takes its build and mode from legacy-identity-target,
# not from this run's publish-nightly; a pending submission is stored and
# continued, never counted as a failure.
# The cmux NIGHTLY-identity chain is three jobs (cx-vws1x): sign, a secret-free
# verify, and publish.
legacy_job_text() {  # <job id>
  awk -v job="  $1:" '$0 == job {on=1; print; next} on && /^  [a-z0-9-]+:$/ {exit} on' "$WORKFLOW_FILE"
}
sign_job="$(legacy_job_text sign-nightly-identity-legacy)"
verify_job="$(legacy_job_text verify-nightly-identity-legacy)"
publish_job="$(legacy_job_text publish-nightly-identity-legacy)"
legacy_job="$sign_job$verify_job$publish_job"
target_job="$(awk '/^  legacy-identity-target:/{on=1} on && /^  [a-z0-9-]+:$/ && !/legacy-identity-target/{exit} on' "$WORKFLOW_FILE")"
for expected in \
  "needs: [decide, build-nightly-app, legacy-identity-target]" \
  "needs.legacy-identity-target.outputs.build != ''" \
  "NIGHTLY_BUILD: \${{ needs.legacy-identity-target.outputs.build }}" \
  "LEGACY_ACTION: \${{ needs.legacy-identity-target.outputs.action }}" \
  "vars.NIGHTLY_NEXT_LEGACY_IDENTITY != 'off'" \
  "group: nightly-next-legacy-identity" \
  "- name: Skip a build the old feed already has" \
  "CMUX_NOTARY_WAIT_TIMEOUT=20m" \
  "CMUX_NOTARY_PENDING_ON_TIMEOUT=true" \
  "CMUX_NOTARY_CONTINUE_STATE=" \
  "- name: Keep the pending cmux NIGHTLY-identity submission" \
  "name: cmux-nightly-identity-pending-meta" \
  "name: cmux-nightly-identity-pending-bundle" \
  "Build \${process.env.BUILD} failed:" \
  "if: always() && steps.failed.outputs.failed == 'true' && steps.resolve.outputs.real != 'false'" \
  ".github/workflows/nightly.yml push nightly-next \$GITHUB_REPOSITORY" \
  "BUNDLE_RUN: \${{ needs.legacy-identity-target.outputs.bundle_run }}" \
  "- name: Store the accepted submission's metadata" \
  '--apple "$apple"' \
  'CMUX_VERIFY_LICENSES_TOOL=$RUNNER_TEMP/build-src/scripts/verify-app-bundle-licenses.sh' \
  "REQUIRED: \${{ vars.NIGHTLY_LEGACY_REQUIRED_COMMITS }}" \
  "requirement in use: required: " \
  'nightly-next-legacy-requirement.sh --commit "$GITHUB_REPOSITORY" "$sha" $REQUIRED' \
  "scripts/ci/nightly-next-legacy-resolve.py" \
  "./scripts/ci/nightly-next-legacy-orphan-meta.sh" \
  'xcrun stapler validate "legacy-app/cmux NIGHTLY.app"'; do
  if ! grep -Fq -- "$expected" <<<"$legacy_job"; then
    echo "FAIL: the cmux NIGHTLY-identity jobs (sign, verify, publish) must contain: $expected"
    exit 1
  fi
done
for expected in \
  "scripts/ci/nightly-next-legacy-target.py next.xml old.xml" \
  "--max-pending-hours 6 --max-same-build-hours 48" \
  "CURRENT_BUILD_SHA: \${{ needs.resolve-nightly-cmux-tui-client.outputs.build_sha }}" \
  "source_sha=\$source_sha" \
  'accepted build $pending_build is not on the live cmux NEXT Nightly feed' \
  '.workflow_run.head_branch == "nightly-next" and .workflow_run.head_repository_id == .workflow_run.repository_id' \
  "for candidate in" \
  "--failure-log failures.txt --max-failures 2" \
  "the bundle of run \$bundle_run is gone" \
  "REQUIRED: \${{ vars.NIGHTLY_LEGACY_REQUIRED_COMMITS }}" \
  "scripts/ci/nightly-next-legacy-requirement.sh" \
  "requirement in use: required: " \
  'grep -q "^Build $build skipped" failures.txt' \
  'NOTES_BASE="${NIGHTLY_NEXT_FEED_BASE}/notes"'; do
  if ! grep -Fq -- "$expected" <<<"$target_job"; then
    echo "FAIL: legacy-identity-target must contain: $expected"
    exit 1
  fi
done
# Split contract (cx-vws1x): the signing job holds the secrets and runs no
# bundle code; the verify job statically verifies the exact DMG with no environment and no
# secret on a literal ephemeral label; publish takes only the verified digest.
for expected in \
  "environment: release-next" \
  "CMUX_DEFER_LAUNCH_SMOKES: \"true\"" \
  "name: cmux-nightly-identity-signed" \
  "dmg_sha256: \${{ steps.handoff.outputs.dmg_sha256 }}" \
  "signed_ok: \${{ steps.attempt.outputs.signed_ok }}" \
  "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || needs.legacy-identity-target.outputs.sign_runner || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}"; do
  grep -Fq -- "$expected" <<<"$sign_job" || { echo "FAIL: sign-nightly-identity-legacy must contain: $expected"; exit 1; }
done
for expected in \
  "NEXT_BUNDLE_ID: \${{ needs.decide.outputs.bundle_id }}" \
  "NEXT_COMMIT_SHORT: \${{ needs.legacy-identity-target.outputs.source_sha }}" \
  "PlistBuddy -c \"Add :SUPublicEDKey string \${NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY}\"" \
  'name: cmux-nightly-remote-daemon' \
  'python3 scripts/verify_remote_daemon_release.py' \
  'python3 scripts/ci/nightly-next-guard.py feed-url "$feed_url"'; do
  grep -Fq -- "$expected" <<<"$publish_job$sign_job" || { echo "FAIL: parallel NEXT identity preparation must contain: $expected"; exit 1; }
done
for expected in \
  "needs: [legacy-identity-target, sign-nightly-identity-legacy]" \
  "runs-on: \${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || needs.legacy-identity-target.outputs.sign_runner || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}" \
  'stapled_flag=(--require-stapled-app)' \
  './scripts/ci/verify-dmg-artifact.sh "$dmg" nightly --expect-sha256 "$SIGNED_SHA256" "${stapled_flag[@]}"' \
  "tested_sha256: \${{ steps.verify.outputs.tested_sha256 }}"; do
  grep -Fq -- "$expected" <<<"$verify_job" || { echo "FAIL: verify-nightly-identity-legacy must contain: $expected"; exit 1; }
done
if grep -Eq 'environment:|secrets\.' <<<"$verify_job" || ! grep -Fq 'vars.MACOS_RUNNER_26' <<<"$verify_job"; then
  echo "FAIL: verify-nightly-identity-legacy must hold no environment or secret and use the trusted macOS pool fallback"
  exit 1
fi
for expected in \
  "needs: [decide, publish-nightly, legacy-identity-target, sign-nightly-identity-legacy, verify-nightly-identity-legacy]" \
  "TESTED_SHA256: \${{ needs.verify-nightly-identity-legacy.outputs.tested_sha256 }}" \
  './scripts/ci/nightly-next-legacy-tested-digest.sh' \
  "group: nightly-next-legacy-identity-publish" \
  "needs.sign-nightly-identity-legacy.result != 'cancelled'" \
  "needs.publish-nightly.outputs.refused != 'true'" \
  "needs.publish-nightly.outputs.build == needs.legacy-identity-target.outputs.build" \
  "needs.publish-nightly.result == 'skipped' && needs.legacy-identity-target.outputs.action == 'continue'" \
  "scripts/ci/nightly-next-legacy-attempt.py --sign-result"; do
  grep -Fq -- "$expected" <<<"$publish_job" || { echo "FAIL: publish-nightly-identity-legacy must contain: $expected"; exit 1; }
done
# Every publishing step of the publish job needs the tested digest, after the check.
for step in "Generate the old feed's appcast" "Publish the cmux NIGHTLY DMG, release notes and the old feed"; do
  step_if="$(awk -v name="      - name: $step" '$0 == name { found=1; next } found && /^        if: / { sub(/^        if: /, ""); print; exit }' <<<"$publish_job")"
  if [ "$step_if" != "steps.order.outputs.skip == 'false' && env.TESTED_SHA256 != ''" ]; then
    echo "FAIL: '$step' must run only with a tested digest: $step_if"
    exit 1
  fi
done
check_line="$(grep -n 'nightly-next-legacy-tested-digest.sh' <<<"$publish_job" | head -1 | cut -d: -f1)"
publish_line="$(grep -n 'gh release upload' <<<"$publish_job" | head -1 | cut -d: -f1)"
if [ -z "$check_line" ] || [ -z "$publish_line" ] || [ "$check_line" -ge "$publish_line" ]; then
  echo "FAIL: publish-nightly-identity-legacy must check the tested digest before it uploads"
  exit 1
fi
if grep -Eq 'smoke-dmg\.sh|smoke-launch|signing-keychain\.sh create' <<<"$publish_job"; then
  echo "FAIL: publish-nightly-identity-legacy must run no bundle code and import no signing keychain"
  exit 1
fi
bash "$ROOT_DIR/tests/test_nightly_next_legacy_tested_digest.sh"

if grep -Fq "publish-nightly.result == 'success'" <<<"$sign_job$verify_job$target_job" || grep -Fq "should_publish == 'true'" <<<"$target_job"; then
  echo "FAIL: the cmux NIGHTLY-identity jobs must not require a publication in the same run (recovered builds publish later)"
  exit 1
fi

# cx-x7hwx class guard: notarize-nightly-dmg.sh runs the bundle notice check,
# which reads ghostty-next/build.zig.zon. Every job that calls it must
# initialize that submodule first (run 38669958906 lost an accepted submission
# without it).
notary_guard="$(awk '
  /^  [a-z0-9-]+:$/ { job=$1; seen_init=0; next }
  /init-submodule\.sh ghostty-next/ && !/^ *#/ { seen_init=1 }
  /scripts\/ci\/notarize-nightly-dmg\.sh/ && !/^ *#/ { if (!seen_init) print job }
' "$WORKFLOW_FILE" | sort -u)"
if [ -n "$notary_guard" ]; then
  echo "FAIL: these jobs call notarize-nightly-dmg.sh without initializing ghostty-next first: $notary_guard"
  exit 1
fi
if ! grep -q 'scripts/ci/notarize-nightly-dmg.sh' <<<"$legacy_job" || ! grep -q '(cd "$RUNNER_TEMP/build-src" && bash scripts/ci/init-submodule.sh ghostty-next)' <<<"$legacy_job"; then
  echo "FAIL: the cmux NIGHTLY-identity job must run the bundle checks from the build's own source with ghostty-next initialized"
  exit 1
fi

echo "PASS: nightly workflow builds once, thins per architecture, and keeps the legacy track migrating"
