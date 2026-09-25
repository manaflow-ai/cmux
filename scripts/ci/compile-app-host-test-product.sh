#!/usr/bin/env bash
# compile-app-host-test-product.sh fingerprint <derived-data>
# compile-app-host-test-product.sh resolve <derived-data> <source-packages>
# compile-app-host-test-product.sh build <derived-data> <source-packages> <cas-path> [log]
#
# Compiles the app-host test product without Xcode's compilation cache (see
# build()). cmuxTests also emits no Swift module. Every job that builds or
# adopts this DerivedData (compile admission, seed-derived-data.yml,
# nightly.yml `refresh-test-compilation-cache`, test-e2e.yml) builds through
# this script, so they pass the same settings and a seed stays incremental.
# The CAS path is still passed; with caching off nothing reads or writes it.
#
# `fingerprint` keys the DerivedData seeds (seed-derived-data.yml, compile
# admission, test-e2e.yml's adopted seed) and an owned Mac's kept state. A
# DerivedData bakes in the absolute source and derived-data paths, and runner
# pools disagree about those paths -- Blacksmith checks out under
# /Users/runner/_work, WarpBuild under /Users/runner/work -- so a seed built on
# one pool would rebuild everything on another.
#
# scripts/ci/canonical-build-root.sh removes that disagreement by building from
# a fixed location every pool can reproduce. When the build runs there the key
# drops the paths, because they are now a constant, and one seed serves every
# pool. A build anywhere else keeps the old path-scoped key, so an unconverted
# lane misses rather than adopting a seed built at other paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: $0 fingerprint <derived-data>" >&2
  echo "       $0 resolve <derived-data> <source-packages>" >&2
  echo "       $0 build <derived-data> <source-packages> <cas-path> [log]" >&2
  echo "prefix fingerprint/resolve/build with canonical- for the shared CI paths" >&2
  exit 64
}

# Same limit as the Release seed in nightly.yml.
cache_limit_bytes=3221225472

# Keep in sync with scripts/ci/canonical-build-root.sh.
CANONICAL_BUILD_ROOT="${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}"

# How Swift Build's llbuild decides a file changed. The default,
# device-agnostic, compares modification times, which cannot survive a move to
# another runner: Blacksmith images install Xcode at different times, so every
# SDK header and prebuilt module a task discovered has another mtime there, and
# Xcode rewrites the generated package module maps with identical bytes on the
# first build after a DerivedData seed is adopted. Run 36022099083 adopted a
# seed of its own base commit and still reran 94 SwiftDriver and 64
# SwiftEmitModule tasks, every third-party package included, for 1,616 Xcode
# files whose only difference was the mtime. checksum-only compares contents,
# so an input that did not change is not rebuilt wherever it came from. Swift
# Build reads the setting from the environment of the xcodebuild that launches
# it, so it reaches only these builds. A build database written in one mode
# reruns every task in the other, so the mode is part of the fingerprint.
XCBUILD_FILE_SYSTEM_MODE=checksum-only

fingerprint() {
  local derived_data="$1"
  # Canonical only when both paths are fixed: the source at the canonical
  # checkout and the derived data directly beneath the canonical root. Its
  # basename still separates purposes, since two purposes are two paths and
  # their entries cannot hit each other.
  if [ "$PWD" = "$CANONICAL_BUILD_ROOT/src" ] \
    && [ "${derived_data%/*}" = "$CANONICAL_BUILD_ROOT" ] \
    && [ "${derived_data##*/}" != "" ]; then
    {
      echo "canonical-v1"
      xcodebuild -version
      printf 'derived-data=%s\n' "${derived_data##*/}"
      printf 'file-system=%s\n' "$XCBUILD_FILE_SYSTEM_MODE"
      echo "compilation-cache=off"
      # The default root adds nothing to the key. Another root (an owned
      # Mac's second compile slot) compiles different absolute paths into
      # the DerivedData, so it gets keys of its own and never adopts a seed
      # made at the default.
      if [ "$CANONICAL_BUILD_ROOT" != /private/tmp/cmux-ci ]; then
        printf 'root=%s\n' "$CANONICAL_BUILD_ROOT"
      fi
    } | shasum -a 256 | cut -c1-32
    return
  fi
  {
    xcodebuild -version
    printf 'workspace=%s\n' "$PWD"
    printf 'derived-data=%s\n' "$derived_data"
    printf 'file-system=%s\n' "$XCBUILD_FILE_SYSTEM_MODE"
    echo "compilation-cache=off"
  } | shasum -a 256 | cut -c1-32
}

# `build` disables package resolution, so a resolve that reports success
# without the Sparkle and Sentry binary artifacts would fail it. A restored
# source-packages cache can do that, and a failed resolve can leave a partial
# clone behind, so every retry starts from an empty package directory.
#
# CMUX_CI_SWIFTPM_CACHE_EXACT_HIT=true says the caller restored the exact
# `spm-` key for this Package.resolved. That cache was saved after a resolve of
# the same pins, so its repositories already hold every pinned revision; try
# once without fetching each package remote. Pins are exact revisions, so
# skipping the fetch cannot change what is checked out. If it fails for any
# reason, fall through to the normal resolve of the same cache.
resolve() {
  local derived_data="$1" source_packages="$2" attempt
  if [ "${CMUX_CI_SWIFTPM_CACHE_EXACT_HIT:-}" = true ]; then
    mkdir -p "$source_packages" "$derived_data"
    if "$SCRIPT_DIR/swiftpm-manifest-cache.sh" run \
      xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
      -derivedDataPath "$derived_data" \
      -clonedSourcePackagesDirPath "$source_packages" \
      -packageCachePath "$source_packages/.package-cache" \
      -skipPackageUpdates \
      -resolvePackageDependencies \
      && [ -d "$source_packages/artifacts/sparkle/Sparkle/Sparkle.xcframework" ] \
      && [ -d "$source_packages/artifacts/sentry-cocoa/Sentry/Sentry.xcframework" ]; then
      return 0
    fi
    echo "Offline resolve from the exact package cache failed; resolving normally" >&2
  fi
  for attempt in 1 2 3; do
    mkdir -p "$source_packages" "$derived_data"
    if "$SCRIPT_DIR/swiftpm-manifest-cache.sh" run \
      xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
      -derivedDataPath "$derived_data" \
      -clonedSourcePackagesDirPath "$source_packages" \
      -packageCachePath "$source_packages/.package-cache" \
      -resolvePackageDependencies; then
      if [ -d "$source_packages/artifacts/sparkle/Sparkle/Sparkle.xcframework" ] \
        && [ -d "$source_packages/artifacts/sentry-cocoa/Sentry/Sentry.xcframework" ]; then
        return 0
      fi
      echo "Resolve succeeded but binary artifacts are missing" >&2
    fi
    # Preserve resolver evidence for transient WarpBuild failures. Diagnostics
    # are advisory and never replace the bounded retry below.
    "$SCRIPT_DIR/capture-network-diagnostics.sh" || true
    [ "$attempt" -lt 3 ] || break
    echo "Package resolution failed on attempt $attempt; clearing packages and retrying" >&2
    rm -rf "$source_packages"
  done
  echo "Failed to resolve Swift packages after 3 attempts" >&2
  return 1
}

build() {
  local derived_data="$1" source_packages="$2" cas_path="$3" log="${4:-/dev/null}"
  local -a module_cache_setting=()
  mkdir -p "$cas_path" "$derived_data"
  if [ -n "${CMUX_CI_MODULE_CACHE_PATH:-}" ]; then
    mkdir -p "$CMUX_CI_MODULE_CACHE_PATH"
    module_cache_setting=("CLANG_MODULE_CACHE_PATH=$CMUX_CI_MODULE_CACHE_PATH")
  fi

  # The scheme list and the product identity come from one place, so a build
  # cannot quietly cover fewer schemes than its key claims. $CMUX_PRODUCT_PROFILE
  # selects it; see PRODUCT_PROFILES in product_input_identity.py, which also
  # documents the ordering.
  local -a schemes=()
  read -r -a schemes <<<"$(python3 "$SCRIPT_DIR/product_input_identity.py" schemes)"
  [ "${#schemes[@]}" -gt 0 ] || { echo "empty product profile scheme list" >&2; exit 1; }
  # cmuxTests emits no Swift module. Nothing imports cmuxTests.swiftmodule,
  # but its separate emit-module job type-checks every declaration in ~1,000
  # files and expands every @Test macro: 26 s of a 31 s one-test-file rebuild,
  # serial. Xcode's integrated driver always emits the module separately; the
  # standalone driver with -no-emit-module-separately emits none. The project
  # sets an empty SWIFT_OBJC_INTERFACE_HEADER_NAME for cmuxTests in every
  # build, because the generated header was the one output that needed the
  # module job and nothing includes it. The same edit took cmuxTests 4.1 s and a
  # full cmuxTests rebuild 105 s instead of 137 s, with the same 11,758
  # enumerated tests (#14352, run 36089490735, 12vcpu).
  # No target builds with the compilation cache. It never hit: compile
  # admission starts every job with an empty CAS (ci-macos.yml deletes it,
  # and no seed or owned Mac keeps it), and on 2026-09-25 21 owned admissions
  # scored 0 to 4 hits against 138 to 4,237 misses; 12 E2E builds, which do
  # restore their own cache, scored 0 to 28 hits against up to 2,581 misses.
  # It cannot do better: an entry covers the whole module's sources and its
  # dependencies' interfaces, so the files an incremental build recompiles
  # are exactly the ones whose entries changed. Under the cache the driver
  # also rewrote the chained bridging header on every build, which forced
  # full cmuxTests rebuilds (#14349) and full app rebuilds before Xcode 26.6
  # (#14359). The fingerprint names this, so no seed built with the cache is
  # adopted by a build without it.
  # shellcheck disable=SC2016 # Xcode expands $(TARGET_NAME), not the shell
  local -a cache_setting=(
    COMPILATION_CACHE_ENABLE_CACHING=NO
    'SWIFT_USE_INTEGRATED_DRIVER=$(CMUX_CI_INTEGRATED_DRIVER_$(TARGET_NAME):default=YES)'
    CMUX_CI_INTEGRATED_DRIVER_cmuxTests=NO
    'OTHER_SWIFT_FLAGS=$(inherited) $(CMUX_CI_SWIFT_FLAGS_$(TARGET_NAME))'
    CMUX_CI_SWIFT_FLAGS_cmuxTests=-no-emit-module-separately
    # A clean build has no module for Xcode's Copy tasks to install (#14371).
    'SWIFT_INSTALL_MODULE=$(CMUX_CI_INSTALL_MODULE_$(TARGET_NAME):default=YES)'
    CMUX_CI_INSTALL_MODULE_cmuxTests=NO
  )
  # shellcheck disable=SC2016 # Xcode expands $(inherited), not the shell
  for scheme in "${schemes[@]}"; do
    FileSystemMode="$XCBUILD_FILE_SYSTEM_MODE" xcodebuild -project cmux.xcodeproj -scheme "$scheme" -configuration Debug \
      -derivedDataPath "$derived_data" \
      -clonedSourcePackagesDirPath "$source_packages" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED' \
      'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks /private/tmp/cmux-app-host-package-frameworks' \
      "${cache_setting[@]}" \
      "COMPILATION_CACHE_CAS_PATH=$cas_path" \
      "COMPILATION_CACHE_LIMIT_SIZE=$cache_limit_bytes" \
      ${module_cache_setting[@]+"${module_cache_setting[@]}"} \
      -showBuildTimingSummary \
      build-for-testing 2>&1 | tee "$derived_data/$scheme-build.log" | tee -a "$log"
  done
}

# The workflow opts both cache writer and reader into this contract together.
# Resolve refreshes the real source tree after dependency downloads. Fingerprint
# needs only the stable cwd; never recopy after resolve, which would erase SPM.
case "${1:-}" in
  canonical-fingerprint|canonical-resolve|canonical-build)
    operation="${1#canonical-}"
    shift
    case "$operation:$#" in
      fingerprint:1|resolve:2|build:3|build:4) ;;
      *) usage ;;
    esac
    [ "${1%/*}" = "$CANONICAL_BUILD_ROOT" ] || { echo "noncanonical DerivedData" >&2; exit 1; }
    if [ "$operation" = resolve ]; then
      "$SCRIPT_DIR/canonical-build-root.sh" "$PWD"
    fi
    # A previous test-only consumer may have left a runtime source alias.
    # Never key, resolve, or compile through its pool-specific realpath: the
    # compiler records the path it opens, so a build behind the alias writes
    # pool-specific cache entries under the pool-independent canonical key.
    # `resolve` re-copies the tree through canonical-build-root.sh above, which
    # strips the alias itself; `fingerprint` and `build` have only this.
    if [ -L "$CANONICAL_BUILD_ROOT/src" ]; then
      rm "$CANONICAL_BUILD_ROOT/src"
    fi
    mkdir -p "$CANONICAL_BUILD_ROOT/src"
    cd "$CANONICAL_BUILD_ROOT/src"
    case "$operation" in
      fingerprint) fingerprint "$1" ;;
      resolve) resolve "$1" "$PWD/.ci-source-packages" ;;
      build) build "$1" "$PWD/.ci-source-packages" "$3" "${4:-/dev/null}" ;;
    esac
    exit
    ;;
esac

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
