#!/usr/bin/env bash
# swiftpm-manifest-cache.sh key
# swiftpm-manifest-cache.sh run <command> [args...]
# swiftpm-manifest-cache.sh stage <dir>
# swiftpm-manifest-cache.sh install <dir>
# swiftpm-manifest-cache.sh clear
#
# Keeps SwiftPM's compiled-manifest cache across CI jobs. Resolving the app
# project evaluates 91 Package.swift files, and with no cache that is most of
# the resolve step: about 45 s of the admission job's resolve went to it even
# on an exact `spm-` package-cache hit.
#
# SwiftPM (the CLI and xcodebuild alike) caches each evaluated manifest in
# ~/Library/Caches/org.swift.swiftpm/manifests/manifest.db, keyed on the
# manifest's contents, its absolute path, the toolchain, and the whole process
# environment minus a short denylist of terminal variables. On Actions every
# step has a different environment (GITHUB_RUN_ID, GITHUB_ACTION, the
# GITHUB_OUTPUT file path), so a restored cache never hits unless the resolve
# runs under a fixed one. `run` supplies that. No cmux Package.swift reads the
# environment, so fixing it cannot change what a manifest declares.
#
# The absolute path stays in the key, so an entry serves only the path it was
# evaluated at. seed-derived-data.yml resolves at each path a reader uses (the
# canonical admission root and the runner workspace) and saves one cache;
# readers restore it read-only.
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# The account's home from the user database, not $HOME: `run` drops HOME, so
# that is where SwiftPM looks, even on a runner that points HOME elsewhere.
# CMUX_CI_SWIFTPM_MANIFEST_CACHE_DIR overrides it for tests.
USER_HOME="$(eval echo "~$(id -un)")"
MANIFEST_CACHE_DIR="${CMUX_CI_SWIFTPM_MANIFEST_CACHE_DIR:-$USER_HOME/Library/Caches/org.swift.swiftpm/manifests}"

usage() {
  echo "usage: $0 key | run <command> [args...] | stage <dir> | install <dir> | clear" >&2
  exit 64
}

# Prints `prefix=` and `key=` for GITHUB_OUTPUT. The prefix names the toolchain,
# since entries from another Xcode can never hit. Entries are content-keyed, so
# a cache from an older revision still serves every manifest that has not
# changed since: readers fall back to the prefix. The full key only decides
# when the seeder writes a new cache.
key() {
  local toolchain inputs
  toolchain="$(xcodebuild -version | shasum -a 256 | cut -c1-16)"
  inputs="$(
    {
      git ls-files -s -- '*Package.swift' 'cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
      # Submodule pointers, since the vendor/bonsplit manifest lives past one.
      git ls-files -s | awk '$1 == "160000"'
      shasum -a 256 "$SCRIPT_PATH" | cut -d' ' -f1
    } | shasum -a 256 | cut -c1-32
  )"
  local prefix="swiftpm-manifests-v1-${RUNNER_OS:-macOS}-${RUNNER_ARCH:-ARM64}-${toolchain}-"
  echo "prefix=$prefix"
  echo "key=$prefix$inputs"
}

# Runs a command under an environment that is the same in every job on a given
# runner image and Xcode. PATH is fixed because steps before a resolve append
# to it differently per workflow (Rust, Bun, Zig); the command itself is still
# found on the caller's PATH. HOME, USER and LOGNAME are dropped too: they
# name the runner account (runner on Blacksmith, cmux on the glaeda minis), so
# keeping them split one seed into one per account, and SwiftPM finds the same
# ~/Library/Caches through the user database without them. TMPDIR is dropped
# so Foundation picks the per-user default. CMUX_CI_SWIFTPM_KEEP_ENV names
# extra variables to keep, for tests whose xcodebuild stub is configured
# through the environment.
run() {
  local command_path
  command_path="$(command -v "$1")" || { echo "$1: command not found" >&2; return 127; }
  shift
  local -a vars=(
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "LANG=en_US.UTF-8"
  )
  local name
  # shellcheck disable=SC2086 # a space-separated list of names
  for name in DEVELOPER_DIR http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY ${CMUX_CI_SWIFTPM_KEEP_ENV:-}; do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [ -n "${!name:-}" ]; then
      vars+=("$name=${!name}")
    fi
  done
  exec env -i "${vars[@]}" "$command_path" "$@"
}

# Copies a consistent manifest.db into <dir> for cache-save. The WAL is folded
# in first; ManifestLoading/ holds per-load diagnostics nothing reads back.
stage() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  if [ ! -f "$MANIFEST_CACHE_DIR/manifest.db" ]; then
    echo "No SwiftPM manifest cache at $MANIFEST_CACHE_DIR" >&2
    return 1
  fi
  sqlite3 "$MANIFEST_CACHE_DIR/manifest.db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
  sqlite3 "$MANIFEST_CACHE_DIR/manifest.db" ".backup '$dir/manifest.db'"
  # A single file: WAL mode would recreate -wal/-shm beside it on every read.
  sqlite3 "$dir/manifest.db" 'PRAGMA journal_mode=DELETE;' >/dev/null
  echo "Staged $(sqlite3 "$dir/manifest.db" 'select count(*) from MANIFEST_CACHE') manifest cache entries ($(du -sh "$dir/manifest.db" | cut -f1))"
  rm -f "$dir/manifest.db-wal" "$dir/manifest.db-shm"
}

# Installs a restored manifest.db as SwiftPM's cache. A missing or unreadable
# restore leaves the runner's own cache alone: the resolve then evaluates
# manifests as it always has.
install() {
  local dir="$1" entries
  if [ ! -f "$dir/manifest.db" ]; then
    echo "No restored SwiftPM manifest cache; resolving without it"
    return 0
  fi
  if ! entries="$(sqlite3 "$dir/manifest.db" 'select count(*) from MANIFEST_CACHE' 2>/dev/null)"; then
    echo "::warning::Restored SwiftPM manifest cache is unreadable; resolving without it"
    return 0
  fi
  mkdir -p "$MANIFEST_CACHE_DIR"
  rm -f "$MANIFEST_CACHE_DIR/manifest.db" "$MANIFEST_CACHE_DIR/manifest.db-wal" "$MANIFEST_CACHE_DIR/manifest.db-shm"
  cp "$dir/manifest.db" "$MANIFEST_CACHE_DIR/manifest.db"
  echo "Installed $entries SwiftPM manifest cache entries"
}

# Empties SwiftPM's manifest cache, so a seed holds only what its resolves use.
clear() {
  rm -rf "$MANIFEST_CACHE_DIR"
}

case "${1:-}" in
  clear) [ "$#" -eq 1 ] || usage; clear ;;
  key) [ "$#" -eq 1 ] || usage; key ;;
  run) [ "$#" -ge 2 ] || usage; shift; run "$@" ;;
  stage) [ "$#" -eq 2 ] || usage; stage "$2" ;;
  install) [ "$#" -eq 2 ] || usage; install "$2" ;;
  *) usage ;;
esac
