#!/usr/bin/env bash
# compile-app-host-test-product.sh fingerprint <derived-data>
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
  build)
    [ "$#" -ge 4 ] && [ "$#" -le 5 ] || usage
    shift
    build "$@"
    ;;
  *)
    usage
    ;;
esac
