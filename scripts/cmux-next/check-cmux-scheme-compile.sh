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
case "$configuration" in
  Debug|Release) ;;
  *) echo "check-cmux-scheme-compile: unsupported configuration '$configuration'" >&2; exit 2 ;;
esac
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
if (( kept_path )); then
  [[ -n "$metrics_dir" ]] || trap 'rm -f "$log"' EXIT
else
  if [[ -n "$metrics_dir" ]]; then
    trap 'rm -rf -- "$derived_data"' EXIT
  else
    trap 'rm -f "$log"; rm -rf -- "$derived_data"' EXIT
  fi
fi
build_attempt=0
build() {
  build_attempt=$((build_attempt + 1))
  if [[ -n "$metrics_dir" ]]; then
    log="$metrics_dir/xcodebuild-attempt-${build_attempt}.log"
  fi
  xcode_args=(
    -project cmux.xcodeproj -scheme cmux -configuration "$configuration"
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$derived_data"
    ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO
  )
  [[ -n "$bundle_id" ]] && xcode_args+=("PRODUCT_BUNDLE_IDENTIFIER=$bundle_id")
  [[ -n "$code_sign_entitlements" ]] && xcode_args+=("CODE_SIGN_ENTITLEMENTS=$code_sign_entitlements")
  [[ -n "$auth_callback_scheme" ]] && xcode_args+=("CMUX_AUTH_CALLBACK_SCHEME=$auth_callback_scheme")
  CMUX_NEXT_SKIP_CEF=1 CMUX_SKIP_ZIG_BUILD=1 \
    "$repo_root/scripts/ci/run-xcodebuild-with-diagnostics.sh" -- \
    xcodebuild "${xcode_args[@]}" \
    -showBuildTimingSummary build 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}
SECONDS=0
if (( kept_path )); then
  # shellcheck source=scripts/ci/swiftpm-binary-module-guard.sh
  source "$repo_root/scripts/ci/swiftpm-binary-module-guard.sh"
  xcode_binary_module_guard "$repo_root" "$derived_data" -project cmux.xcodeproj -scheme cmux
fi
status=0
build || status=$?
if (( status && kept_path )) && "$repo_root/scripts/cmux-next/stale-pcm-retry-needed.sh" "$log"; then
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
exit "$status"
