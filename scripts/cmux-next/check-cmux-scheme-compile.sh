#!/usr/bin/env bash
# Compile the cmux app scheme (cmux.xcodeproj: the app host and every local
# package it links, CmuxControlSocket among them) for arm64, without signing,
# CEF or the zig CLI. The default remains the Debug cmux DEV build used by
# dogfood; CMUX_NEXT_CONFIGURATION and the product overrides are used by the
# separate Release cmux NEXT DEV channel.
#
# Why: the cmux-next package checks build CmuxNext only. A merge from main
# once re-added files to CmuxControlSocket that extend types this branch had
# deleted, and nothing failed until fleet dev builds did (exit 65).
#
# GhosttyNextKit comes from SwiftPM (Packages/Shared/CmuxGhosttyKit). Needs
# the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch), which the
# Bundle cmux-tui phase copies instead of building it from source.
#
# Usage: scripts/cmux-next/check-cmux-scheme-compile.sh [derived-data-path]
#   default derived data: a new directory in $TMPDIR (per fleet step),
#   removed when the script ends. Never a host-shared fixed path: explicit
#   precompiled modules are keyed by compile arguments, not header content, so
#   a kept host-wide DerivedData reused modules built from an older xcframework
#   header (check-release-compile.sh failed this way on cmuxs-Mac-mini-4,
#   2026-10-06). A caller's path (the glaeda job's per-runner cache) builds
#   incrementally and is kept. Before its build the binary-module guard
#   (scripts/ci/swiftpm-binary-module-guard.sh, xcode_binary_module_guard)
#   removes its build outputs when a binary target's headers changed since the
#   last build there; precompiled modules that still fail as stale are dropped
#   and the build retried once, as the fleet's dev builds do. A fresh
#   directory has no such modules, so it is neither guarded nor retried.
#
# CMUX_NEXT_BROWSER_DATA_IMPORT=compiled-out compiles the browser-data import
# out exactly as nightly.yml does for every nightly-next build (cx-f58x: Apple
# notarizes cmux-next only without it): OTHER_SWIFT_FLAGS gains
# -DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT and
# browser-sources.json is emptied for the build, then restored. Any other
# value (the default) builds the import in. The caller proves the result with
# scripts/ci/check-browser-data-import-absent.sh and
# scripts/ci/check-password-import-readers.sh.
set -euo pipefail

# xcodebuild compiles the app: fleet or GitHub runner only.
# shellcheck source-path=SCRIPTDIR source=lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-only.sh"
cmux_next_require_fleet check-cmux-scheme-compile.sh "xcodebuild" "cmux app scheme compile (Debug)"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
configuration="${CMUX_NEXT_CONFIGURATION:-Debug}"
product_name="${CMUX_NEXT_PRODUCT_NAME:-}"
bundle_id="${CMUX_NEXT_BUNDLE_ID:-}"
code_sign_entitlements="${CMUX_NEXT_CODE_SIGN_ENTITLEMENTS:-}"
auth_callback_scheme="${CMUX_NEXT_AUTH_CALLBACK_SCHEME:-}"
browser_data_import="${CMUX_NEXT_BROWSER_DATA_IMPORT:-built-in}"
# Build-mode overrides (the DEV Release channel; empty keeps the project's).
compilation_cache="${CMUX_NEXT_COMPILATION_CACHE:-0}"
swift_compilation_mode="${CMUX_NEXT_SWIFT_COMPILATION_MODE:-}"
case "$configuration" in
  Debug|Release) ;;
  *) echo "check-cmux-scheme-compile: unsupported configuration '$configuration'" >&2; exit 2 ;;
esac
case "$compilation_cache" in 0|1) ;; *) echo "check-cmux-scheme-compile: CMUX_NEXT_COMPILATION_CACHE must be 0 or 1, not '$compilation_cache'" >&2; exit 2 ;; esac
case "$swift_compilation_mode" in ""|wholemodule|singlefile) ;; *) echo "check-cmux-scheme-compile: unsupported CMUX_NEXT_SWIFT_COMPILATION_MODE '$swift_compilation_mode'" >&2; exit 2 ;; esac
kept_path=0
if [[ -n "${1:-}" ]]; then
  derived_data="$1"
  kept_path=1
else
  derived_data="$(mktemp -d "${TMPDIR:-/tmp}/cmux-scheme-compile.XXXXXX")"
fi

echo "check-cmux-scheme-compile: $(xcodebuild -version | tr '\n' ' ')"
cd "$repo_root"
metrics_dir="${CMUX_BUILD_METRICS_DIR:-}"
if [[ -n "$metrics_dir" ]]; then
  if mkdir -p "$metrics_dir"; then
    log=""
  else
    echo "warning: cannot create CMUX_BUILD_METRICS_DIR=$metrics_dir; continuing without timing artifacts" >&2
    metrics_dir=""
    log="$(mktemp -t cmux-next-scheme-build.XXXXXX.log)"
  fi
else
  log="$(mktemp)"
fi
remove_log=0
remove_derived_data=0
# With metrics on, each attempt also writes a result bundle (outside the
# uploaded metrics directory), read once for the build timeline below.
timeline_dir=""
[[ -z "$metrics_dir" ]] || timeline_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-scheme-timeline.XXXXXX")" || timeline_dir=""
[[ -n "$metrics_dir" ]] || remove_log=1
(( kept_path )) || remove_derived_data=1
browser_sources="Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Resources/browser-sources.json"
browser_sources_backup=""
# shellcheck source-path=SCRIPTDIR source=lib/workspace-resolved.sh
source "$repo_root/scripts/cmux-next/lib/workspace-resolved.sh"
# shellcheck disable=SC2329 # run by the EXIT trap
on_exit() {
  if [[ -n "$browser_sources_backup" ]]; then
    cp -f "$browser_sources_backup" "$repo_root/$browser_sources" && rm -f "$browser_sources_backup"
  fi
  # xcodebuild may rewrite the committed Package.resolved; a dirty tracked
  # file makes the next job on a reused GitHub runner reset the whole
  # workspace and rebuild every module (lib/workspace-resolved.sh). Only on
  # a GitHub runner: a fleet step's checkout is its own.
  [[ "${GITHUB_ACTIONS:-}" != true ]] || cmux_next_restore_workspace_resolved "$repo_root"
  if (( remove_log )); then rm -f "$log"; fi
  if (( remove_derived_data )); then rm -rf -- "$derived_data"; fi
  if [[ -n "$timeline_dir" ]]; then rm -rf -- "$timeline_dir"; fi
}
trap on_exit EXIT
swift_import_flags=""
if [[ "$browser_data_import" == compiled-out ]]; then
  swift_import_flags="-DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT"
  browser_sources_backup="$(mktemp "${TMPDIR:-/tmp}/browser-sources.XXXXXX")"
  cp -f "$browser_sources" "$browser_sources_backup"
  cp -f "$repo_root/scripts/cmux-next/lib/browser-sources-compiled-out.json" "$browser_sources"
fi
echo "check-cmux-scheme-compile: browser-data import ${browser_data_import} (flags: ${swift_import_flags:-none})"
build_attempt=0
build() {
  build_attempt=$((build_attempt + 1))
  if [[ -n "$metrics_dir" ]]; then
    log="$metrics_dir/xcodebuild-attempt-${build_attempt}.log"
  fi
  result_bundle=""
  [[ -z "$timeline_dir" ]] || result_bundle="$timeline_dir/attempt-${build_attempt}.xcresult"
  xcode_args=(
    -project cmux.xcodeproj -scheme cmux -configuration "$configuration"
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$derived_data"
    ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO
    # This is a compile check; release packaging retains the project dSYM setting.
    DEBUG_INFORMATION_FORMAT=dwarf
  )
  [[ -n "$bundle_id" ]] && xcode_args+=("PRODUCT_BUNDLE_IDENTIFIER=$bundle_id")
  # A dev bundle id (the DEV Release app) never claims http/https at Default
  # rank, whatever the configuration (Resources/Info.plist; tests/test_web_url_handler_rank.py).
  if [[ -n "$bundle_id" ]]; then
    web_url_handler_rank=Default
    case "$bundle_id" in com.cmuxterm.app.debug|com.cmuxterm.app.debug.*|com.cmuxterm.app.staging|com.cmuxterm.app.staging.*) web_url_handler_rank=Alternate ;; esac
    xcode_args+=("CMUX_WEB_URL_HANDLER_RANK=$web_url_handler_rank")
  fi
  [[ -n "$code_sign_entitlements" ]] && xcode_args+=("CODE_SIGN_ENTITLEMENTS=$code_sign_entitlements")
  [[ -n "$auth_callback_scheme" ]] && xcode_args+=("CMUX_AUTH_CALLBACK_SCHEME=$auth_callback_scheme")
  # shellcheck disable=SC2016 # $(inherited) is an Xcode build setting, not a shell expansion
  [[ -n "$swift_import_flags" ]] && xcode_args+=("OTHER_SWIFT_FLAGS=\$(inherited) $swift_import_flags")
  [[ -n "$swift_compilation_mode" ]] && xcode_args+=("SWIFT_COMPILATION_MODE=$swift_compilation_mode")
  # The Linux whole-app build's REF capture (hybrid_ref_capture.py) reads the frontend lines from the log.
  [[ "${CMUX_NEXT_EMIT_FRONTEND_COMMAND_LINES:-}" == 1 ]] && xcode_args+=(EMIT_FRONTEND_COMMAND_LINES=YES)
  if (( use_cache )); then
    while IFS= read -r setting; do xcode_args+=("$setting"); done < <(cmux_next_cas_settings)
  fi
  [[ -z "$result_bundle" ]] || xcode_args+=(-resultBundlePath "$result_bundle")
  CMUX_NEXT_SKIP_CEF=1 CMUX_SKIP_ZIG_BUILD=1 \
    "$repo_root/scripts/ci/run-xcodebuild-with-diagnostics.sh" -- \
    xcodebuild "${xcode_args[@]}" \
    -showBuildTimingSummary build 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}
# The compilation cache only pays on a kept path (a fresh directory starts
# with an empty cache); there it replaces the kept build products
# (lib/compilation-cache.sh).
use_cache=0
if [[ "$compilation_cache" == 1 ]] && (( kept_path )); then
  # shellcheck source-path=SCRIPTDIR source=lib/compilation-cache.sh
  source "$repo_root/scripts/cmux-next/lib/compilation-cache.sh"
  use_cache=1
  # The cache keys hold this path: use its real path (no /tmp symlink).
  mkdir -p "$derived_data" && derived_data="$(cd "$derived_data" && pwd -P)"
  if ! cmux_next_cas_fresh_tree "$derived_data"; then
    # Never build on leftover products: start over with nothing kept.
    echo "::warning::could not empty $derived_data around its compilation cache; removing it whole"
    rm -rf -- "$derived_data"
    [[ ! -e "$derived_data" ]] || { echo "check-cmux-scheme-compile: cannot clear $derived_data; refusing to build on stale products" >&2; exit 1; }
    mkdir -p "$derived_data"
  fi
fi
echo "check-cmux-scheme-compile: compilation cache $( (( use_cache )) && echo on || echo off), SWIFT_COMPILATION_MODE=${swift_compilation_mode:-project}"
SECONDS=0
# A cache build starts from a fresh tree: like a fresh directory it has no
# precompiled modules to guard or clear (and the guard would remove the cache).
if (( kept_path && ! use_cache )); then
  # shellcheck source=scripts/ci/swiftpm-binary-module-guard.sh
  source "$repo_root/scripts/ci/swiftpm-binary-module-guard.sh"
  xcode_binary_module_guard "$repo_root" "$derived_data" -project cmux.xcodeproj -scheme cmux
fi
status=0
build || status=$?
if (( status && use_cache )) && cmux_next_cas_failed "$log"; then
  echo "::warning::the compilation cache failed (not the code); dropping it and building once more without it"
  cmux_next_cas_drop "$derived_data"
  cmux_next_cas_fresh_tree "$derived_data" \
    || { echo "check-cmux-scheme-compile: cannot clear $derived_data after the cache failure" >&2; exit 1; }
  use_cache=0
  status=0
  build || status=$?
fi
if (( status && kept_path && ! use_cache )) && "$repo_root/scripts/cmux-next/stale-pcm-retry-needed.sh" "$log"; then
  echo "check-cmux-scheme-compile: stale precompiled modules in $derived_data; removing them and building again"
  "$repo_root/scripts/cmux-next/clear-stale-scheme-build-state.sh" "$derived_data"
  status=0
  build || status=$?
fi
# A product name renames the built app afterwards, as reload.sh does. Passed to
# xcodebuild, PRODUCT_NAME would rename every target, and every package's
# resource bundle would then be written to the same "<name>.bundle".
if (( status == 0 )) && [[ -n "$product_name" ]]; then
  case "$configuration" in
    Release) built_name="cmux" ;;
    Debug) built_name="cmux DEV" ;;
  esac
  products="$derived_data/Build/Products/$configuration"
  built="$products/$built_name.app"
  renamed="$products/$product_name.app"
  [[ -d "$built" ]] || { echo "check-cmux-scheme-compile: no $built_name.app in $products" >&2; exit 1; }
  rm -rf -- "$renamed"
  /bin/cp -cR "$built" "$renamed"
  plist="$renamed/Contents/Info.plist"
  for key in CFBundleName CFBundleDisplayName; do
    /usr/libexec/PlistBuddy -c "Set :$key $product_name" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :$key string $product_name" "$plist"
  done
  echo "check-cmux-scheme-compile: $product_name.app from $built_name.app"
fi
# Prune the cache whatever the build's outcome; it never changes the verdict.
[[ "$compilation_cache" != 1 ]] || ! (( kept_path )) || cmux_next_cas_bound "$repo_root" "$derived_data"
if [[ -n "${CMUX_BUILD_METRICS_OUTPUT:-}" ]]; then
  # Keep the final log beside DerivedData so the existing parser can report
  # Xcode's phase summary and cache remarks. Metrics are advisory: a parser or
  # upload problem must never change the compile verdict.
  cp -f "$log" "$derived_data/cmux-next-build.log" 2>/dev/null || true
  metrics_args=(--output "$CMUX_BUILD_METRICS_OUTPUT" --compile-seconds "$SECONDS")
  metrics_args+=(--compile-outcome "$([[ "$status" == 0 ]] && echo success || echo failure)")
  [[ -n "${CMUX_BUILD_METRICS_SUMMARY:-}" ]] && metrics_args+=(--summary "$CMUX_BUILD_METRICS_SUMMARY")
  python3 "$repo_root/scripts/ci/build_metrics.py" "$derived_data" "${metrics_args[@]}" \
    || echo "check-cmux-scheme-compile: warning: could not write build metrics" >&2
fi
# Where the time went: per task kind and the slowest tasks
# (scripts/ci/xcode_build_timeline.py). Advisory and after the
# metrics, so it changes neither the verdict nor the recorded compile seconds.
if [[ -n "$timeline_dir" && -d "${result_bundle:-}" ]]; then
  python3 "$repo_root/scripts/ci/xcode_build_timeline.py" --xcresult "$result_bundle" \
    --json "$metrics_dir/build-timeline.json" || true
fi
exit "$status"
