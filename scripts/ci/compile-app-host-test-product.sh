#!/usr/bin/env bash
# compile-app-host-test-product.sh fingerprint <derived-data>
# compile-app-host-test-product.sh build <derived-data> <source-packages> <cas-path> [log]
#
# Compiles the app-host test product (cmux-unit, then cmux-numeric-locale) with
# Xcode's compilation cache on. Two jobs call this and nothing else may build
# the product by hand:
#
#   - ci.yml `macos-compile-admission`, which restores the cache read-only.
#   - nightly.yml `refresh-test-compilation-cache`, which builds main on a
#     schedule and saves the cache that the admission job restores.
#
# A compilation cache entry is keyed on the full compiler invocation, and CI
# builds without path prefix mapping, so the two jobs only share hits while
# they pass the same build settings from the same absolute paths. Keeping the
# invocation here is what holds them together: change a flag in one place and
# both the seed and its reader move with it.
#
# `fingerprint` prints the part of the cache key that says whether a seed can
# hit at all: the toolchain and the absolute paths the compiler sees. Runner
# pools lay the workspace out differently (/Users/runner/_work on Blacksmith,
# /Users/runner/work on Warp, which is where fork pull requests land because
# repository variables are not exposed to them), and a seed from another layout
# misses every job that names a path. Keying on the layout turns that into a
# cache miss instead of a gigabyte download that cannot help.
set -euo pipefail

usage() {
  echo "usage: $0 fingerprint <derived-data>" >&2
  echo "       $0 build <derived-data> <source-packages> <cas-path> [log]" >&2
  exit 64
}

# Matches the Release seed in nightly.yml. The CAS rotates its primary
# generation above half of this, and prune-xcode-compilation-cache.py drops the
# dead generation before the seed is measured and saved.
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
