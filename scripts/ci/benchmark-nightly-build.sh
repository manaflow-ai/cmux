#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <universal-wmo|universal-singlefile|arm64-wmo|x86_64-wmo> [results-dir]" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 2
fi

scenario="$1"
results_dir="${2:-benchmark-results/$scenario}"
case "$scenario" in
  universal-wmo)
    archs="arm64 x86_64"
    compilation_mode="wholemodule"
    phases="full"
    ;;
  universal-singlefile)
    archs="arm64 x86_64"
    compilation_mode="singlefile"
    phases="full"
    ;;
  arm64-wmo)
    archs="arm64"
    compilation_mode="wholemodule"
    phases="cold"
    ;;
  x86_64-wmo)
    archs="x86_64"
    compilation_mode="wholemodule"
    phases="cold"
    ;;
  *)
    usage
    exit 2
    ;;
esac

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
mkdir -p "$results_dir"
results_dir="$(cd "$results_dir" && pwd)"
derived_data="$RUNNER_TEMP/cmux-nightly-benchmark-$scenario"
source_file="$root/Sources/CmuxEventBus.swift"
source_backup="$RUNNER_TEMP/CmuxEventBus.swift.$scenario"
cp "$source_file" "$source_backup"

cleanup() {
  cp "$source_backup" "$source_file"
}
trap cleanup EXIT

summary="$results_dir/summary.md"
metrics="$results_dir/metrics.tsv"
printf 'phase\tseconds\n' > "$metrics"

build_phase() {
  local phase="$1"
  local started elapsed
  started="$(date +%s)"
  CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
    -scheme cmux \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -destination 'generic/platform=macOS' \
    -clonedSourcePackagesDirPath .spm-cache \
    -showBuildTimingSummary \
    ARCHS="$archs" \
    ONLY_ACTIVE_ARCH=NO \
    SWIFT_COMPILATION_MODE="$compilation_mode" \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    COMPILATION_CACHE_ENABLE_CACHING=YES \
    COMPILATION_CACHE_LIMIT_SIZE=3221225472 \
    COMPILER_INDEX_STORE_ENABLE=NO \
    CODE_SIGNING_ALLOWED=NO \
    ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly \
    build 2>&1 | tee "$results_dir/$phase.log"
  elapsed=$(( $(date +%s) - started ))
  printf '%s\t%s\n' "$phase" "$elapsed" >> "$metrics"
}

assert_release_settings() {
  local settings="$results_dir/build-settings.txt"
  xcodebuild \
    -scheme cmux \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    ARCHS="$archs" \
    SWIFT_COMPILATION_MODE="$compilation_mode" \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    -showBuildSettings > "$settings"
  grep -Eq '^[[:space:]]*SWIFT_OPTIMIZATION_LEVEL = -O$' "$settings"
  grep -Eq "^[[:space:]]*SWIFT_COMPILATION_MODE = $compilation_mode$" "$settings"
}

inspect_cold_artifact() {
  local products app info executable binary actual_archs archive stripped_app
  local uuid_before uuid_after dsym_uuid unstripped_bytes stripped_bytes binary_bytes
  products="$derived_data/Build/Products/Release"
  app="$products/cmux.app"
  info="$app/Contents/Info.plist"
  if [ ! -d "$app" ]; then
    echo "error: expected app missing at $app" >&2
    exit 1
  fi
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
  binary="$app/Contents/MacOS/$executable"
  actual_archs="$(lipo -archs "$binary")"
  for arch in $archs; do
    lipo "$binary" -verify_arch "$arch"
  done

  archive="$results_dir/unstripped-app.tar.gz"
  tar -C "$products" -czf "$archive" cmux.app
  unstripped_bytes="$(stat -f %z "$archive")"
  binary_bytes="$(stat -f %z "$binary")"

  uuid_before="$("$root/scripts/ci/macho-uuid-keys.sh" "$binary")"
  dsym_uuid="$("$root/scripts/ci/macho-uuid-keys.sh" "$products/cmux.app.dSYM")"
  if [ -z "$(comm -12 <(printf '%s\n' "$uuid_before") <(printf '%s\n' "$dsym_uuid"))" ]; then
    echo "error: app and dSYM UUIDs do not intersect" >&2
    exit 1
  fi

  stripped_app="$RUNNER_TEMP/cmux-stripped-$scenario.app"
  ditto "$app" "$stripped_app"
  "$root/scripts/strip-release-bundle.sh" "$stripped_app"
  uuid_after="$("$root/scripts/ci/macho-uuid-keys.sh" "$stripped_app/Contents/MacOS/$executable")"
  if [ "$uuid_before" != "$uuid_after" ]; then
    echo "error: stripping changed the app Mach-O UUID" >&2
    exit 1
  fi
  tar -C "$RUNNER_TEMP" -czf "$results_dir/stripped-app.tar.gz" "$(basename "$stripped_app")"
  stripped_bytes="$(stat -f %z "$results_dir/stripped-app.tar.gz")"

  {
    printf 'actual_archs\t%s\n' "$actual_archs"
    printf 'binary_bytes\t%s\n' "$binary_bytes"
    printf 'unstripped_archive_bytes\t%s\n' "$unstripped_bytes"
    printf 'stripped_archive_bytes\t%s\n' "$stripped_bytes"
  } >> "$metrics"

  if [ "$archs" = "arm64 x86_64" ]; then
    CMUX_SMOKE_DIRECT_EXEC=1 \
      CMUX_SMOKE_STARTUP_TIMEOUT_SECONDS=15 \
      CMUX_SMOKE_STABLE_SECONDS=5 \
      "$root/scripts/smoke-launch-macos-app.sh" "$app" | tee "$results_dir/smoke.log"
  fi
}

rm -rf "$derived_data"
assert_release_settings
build_phase cold
inspect_cold_artifact

if [ "$phases" = "full" ]; then
  build_phase noop-warm

  cache_path="$derived_data/CompilationCache.noindex"
  if [ ! -d "$cache_path" ]; then
    echo "error: Xcode compilation cache was not produced" >&2
    exit 1
  fi
  find "$derived_data" -mindepth 1 -maxdepth 1 ! -name CompilationCache.noindex -exec rm -rf {} +
  printf '\n// nightly benchmark source change: %s\n' "$scenario" >> "$source_file"
  build_phase one-file-cache-only
fi

{
  echo "# Nightly build benchmark: $scenario"
  echo
  echo "- Xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "- Architectures: $archs"
  echo "- Swift compilation mode: $compilation_mode"
  echo "- Swift optimization: -O"
  echo
  echo '| Phase | Seconds |'
  echo '| --- | ---: |'
  awk -F '\t' 'NR > 1 && $1 ~ /^(cold|noop-warm|one-file-cache-only)$/ { printf "| %s | %s |\n", $1, $2 }' "$metrics"
  echo
  echo '| Artifact | Value |'
  echo '| --- | ---: |'
  awk -F '\t' '$1 !~ /^(phase|cold|noop-warm|one-file-cache-only)$/ { printf "| %s | %s |\n", $1, $2 }' "$metrics"
} > "$summary"

cat "$summary"
