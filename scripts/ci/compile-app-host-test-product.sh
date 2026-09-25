#!/usr/bin/env bash
# compile-app-host-test-product.sh fingerprint <derived-data>
# compile-app-host-test-product.sh resolve <derived-data> <source-packages>
# compile-app-host-test-product.sh build <derived-data> <source-packages> <cas-path> [log]
#
# Compiles the app-host test product with Xcode's compilation cache on for
# every target except cmuxTests, and except the app before Xcode 26.6 (see
# build()). ci.yml
# `macos-compile-admission` restores that cache read-only and nightly.yml
# `refresh-test-compilation-cache` writes it. A cache entry is keyed on the
# whole compiler invocation and on absolute paths, so both jobs must build
# through this script or they stop sharing hits without anything failing.
#
# `fingerprint` keys the cache. A cache entry bakes in the absolute source and
# derived-data paths, so which paths the build used decides whether a seed can
# hit at all. Runner pools disagree about those paths -- Blacksmith checks out
# under /Users/runner/_work, WarpBuild under /Users/runner/work -- so a seed
# built on one pool could never hit on another.
#
# scripts/ci/canonical-build-root.sh removes that disagreement by building from
# a fixed location every pool can reproduce. When the build runs there the key
# drops the paths, because they are now a constant, and one seed serves every
# pool. A build anywhere else keeps the old path-scoped key and its own private
# cache, so an unconverted lane degrades to a miss rather than downloading a
# seed whose entries cannot hit.
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
      # The default root adds nothing, so every existing seed and cache key
      # stays the same. Another root (an owned Mac's second compile slot)
      # compiles different absolute paths into every entry, so it gets keys
      # of its own and never adopts a seed or cache made at the default.
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

# True when the selected Xcode (DEVELOPER_DIR, else xcode-select) is older than
# <major>.<minor>. An unreadable version counts as not older.
xcode_older_than() {
  local want_major="$1" want_minor="$2" version major minor
  version="$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
  major="${version%%.*}"
  minor="${version#"$major"}"
  minor="${minor#.}"
  minor="${minor%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  [ "$major" -lt "$want_major" ] || { [ "$major" -eq "$want_major" ] && [ "$minor" -lt "$want_minor" ]; }
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
  # cmuxTests builds without the compilation cache. Under the cache its driver
  # regenerates cmuxTests-*-ChainedBridgingHeader.h (the app's bridging header,
  # reached through @testable import) on every build, and that newer header
  # invalidates all ~1,100 inputs: a one-test-file edit recompiled every file
  # (1,355 CPU s). Without the cache the driver's incremental build works: the
  # same edit compiled one task and cmuxTests took 31 s instead of 139 s
  # (#14249, run 36081880621, 12vcpu). Command-line settings are evaluated per
  # target, so every other target keeps the cache and its arguments.
  # shellcheck disable=SC2016 # Xcode expands $(TARGET_NAME), not the shell
  local -a cache_setting=(
    'COMPILATION_CACHE_ENABLE_CACHING=$(CMUX_CI_COMPILATION_CACHE_$(TARGET_NAME):default=YES)'
    CMUX_CI_COMPILATION_CACHE_cmuxTests=NO
  )
  # Before Xcode 26.6 the app target has the same defect: under the cache the
  # driver rewrites cmux_DEV-*-ChainedBridgingHeader.h and the bridging PCH
  # (identical bytes, newer mtime) on every build, so a body-only edit to one
  # file recompiled all ~5,200 files, 448-495 s on the macOS 15 pool (Xcode
  # 26.3). With the cache off for `cmux` the same edit compiled 2 tasks in 41 s
  # (#14351, run 36086596738). On Xcode 26.6 the app compiles incrementally
  # with the cache on (1 task, run 36081880621), so it keeps the cache there.
  if xcode_older_than 26 6; then
    cache_setting+=(CMUX_CI_COMPILATION_CACHE_cmux=NO)
  fi
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
      'OTHER_SWIFT_FLAGS=$(inherited) $(CMUX_CI_TARGET_FLAGS_$(TARGET_NAME))' \
      CMUX_CI_TARGET_FLAGS_cmux=-driver-show-incremental \
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
