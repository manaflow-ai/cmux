#!/usr/bin/env bash
# compile-app-host-test-product.sh fingerprint <derived-data>
# compile-app-host-test-product.sh resolve <derived-data> <source-packages>
# compile-app-host-test-product.sh build <derived-data> <source-packages> <cas-path> [log]
#
# Compiles the app-host test product with Xcode's compilation cache on. ci.yml
# `macos-compile-admission` restores that cache read-only and nightly.yml
# `refresh-test-compilation-cache` writes it. A cache entry is keyed on the
# whole compiler invocation and on absolute paths, so both jobs must build
# through this script or they stop sharing hits without anything failing.
#
# `fingerprint` hashes the toolchain and the build paths into the cache key.
# Runner pools lay the workspace out differently, and a seed built under
# another layout cannot hit, so it should be a cache miss and not a download.
set -euo pipefail

usage() {
  echo "usage: $0 fingerprint <derived-data>" >&2
  echo "       $0 resolve <derived-data> <source-packages>" >&2
  echo "       $0 build <derived-data> <source-packages> <cas-path> [log]" >&2
  exit 64
}

# Same limit as the Release seed in nightly.yml.
cache_limit_bytes=3221225472

fingerprint() {
  local derived_data="$1"
  {
    xcodebuild -version
    printf 'workspace=%s\n' "$PWD"
    printf 'derived-data=%s\n' "$derived_data"
  } | shasum -a 256 | cut -c1-32
}

# `build` disables package resolution, so a resolve that reports success
# without the Sparkle and Sentry binary artifacts would fail it. A restored
# source-packages cache can do that; clear it and resolve again.
resolve() {
  local derived_data="$1" source_packages="$2" attempt
  for attempt in 1 2 3; do
    mkdir -p "$source_packages" "$derived_data"
    if xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
      -derivedDataPath "$derived_data" \
      -clonedSourcePackagesDirPath "$source_packages" \
      -resolvePackageDependencies; then
      if [ -d "$source_packages/artifacts/sparkle/Sparkle/Sparkle.xcframework" ] \
        && [ -d "$source_packages/artifacts/sentry-cocoa/Sentry/Sentry.xcframework" ]; then
        return 0
      fi
      echo "Resolve succeeded but binary artifacts are missing; clearing and retrying" >&2
      rm -rf "$source_packages"
    fi
    [ "$attempt" -lt 3 ] || break
    echo "Package resolution failed on attempt $attempt, retrying..." >&2
    sleep $((attempt * 5))
  done
  echo "Failed to resolve Swift packages after 3 attempts" >&2
  return 1
}

build() {
  local derived_data="$1" source_packages="$2" cas_path="$3" log="${4:-/dev/null}"
  mkdir -p "$cas_path"

  # shellcheck disable=SC2016 # Xcode expands $(inherited), not the shell
  for scheme in cmux-unit cmux-numeric-locale; do
    xcodebuild -project cmux.xcodeproj -scheme "$scheme" -configuration Debug \
      -derivedDataPath "$derived_data" \
      -clonedSourcePackagesDirPath "$source_packages" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED' \
      'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks /private/tmp/cmux-app-host-package-frameworks' \
      COMPILATION_CACHE_ENABLE_CACHING=YES \
      "COMPILATION_CACHE_CAS_PATH=$cas_path" \
      "COMPILATION_CACHE_LIMIT_SIZE=$cache_limit_bytes" \
      build-for-testing 2>&1 | tee -a "$log"
  done
}

case "${1:-}" in
  fingerprint)
    [ "$#" -eq 2 ] || usage
    fingerprint "$2"
    ;;
  resolve)
    [ "$#" -eq 3 ] || usage
    resolve "$2" "$3"
    ;;
  build)
    [ "$#" -ge 4 ] && [ "$#" -le 5 ] || usage
    shift
    build "$@"
    ;;
  *)
    usage
    ;;
esac
