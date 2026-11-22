# shellcheck shell=bash
# Sourced by app-build-release.sh: take the nightly Mac's one build root, or keep the slot's own.
#
# Xcode's compilation cache keys hold the absolute source, DerivedData and package checkout paths.
# Each runner slot built in its own workspace into its own kept DerivedData, so one module had a
# different key on every slot, the slots pushed each other's entries out of the size-capped CAS, and
# each slot's incremental build compared against its own last build several tips back
# (nightly_build_state.py). Here every dedicated slot builds from the same tree instead:
#
# - HOST_ROOT/src is this checkout cloned whole (canonical-build-root.sh: the old tree goes first,
#   an APFS clone with an rsync fallback, .git and the products earlier steps put in the checkout
#   come along), HOST_ROOT/DerivedData the kept DerivedData, HOST_ROOT/SourcePackages the packages.
#   The root is the same path on every nightly Mac.
# - flock(2) on HOST_ROOT/lock through fd 9 (scripts/cmux-next/host_build_lock.py), never waited for. xcodebuild and
#   every other child inherit fd 9, so the kernel holds the lock until the last of them exits,
#   however the step ends, and no lock outlives them.
# - A held lock, a lock error or a failed setup builds on the slot's own state (the earlier
#   "Start Release DerivedData empty" step prepared it) at once.
#
# Sets build_root and derived_data (the build reads them) and host_root ('' when not taken).
# CMUX_NIGHTLY_HOST_ROOT names another root; CMUX_NIGHTLY_HOST_BUILD_ROOT=0 switches this off.
# shellcheck disable=SC2034 # read by app-build-release.sh
host_root=""
build_root="$PWD"
derived_data=build-universal
nightly_host_root_take() {
  local workspace="$PWD" root="${CMUX_NIGHTLY_HOST_ROOT:-/Users/Shared/cmux-build-fleet/xcode/nightly-next}"
  local status=0 head
  # A cold measurement run (DECIDE_COLD_CACHE_DISABLE) builds on nothing kept.
  [[ "${BUILD_TRACK:-}" == nightly-next && "${CMUX_NIGHTLY_HOST_BUILD_ROOT:-}" == 1 && -z "${DECIDE_COLD_CACHE_DISABLE:-}" ]] || return 0
  if ! { mkdir -p "$root" && exec 9>>"$root/lock"; }; then
    echo "::notice title=nightly host build root::cannot open $root/lock; building in this slot's own tree"
    return 0
  fi
  python3 -I scripts/cmux-next/host_build_lock.py acquire "$root/lock" --fd 9 || status=$?
  if (( status != 0 )); then
    exec 9>&-
    echo "::notice title=nightly host build root::$root is busy or unusable (status $status); building in this slot's own tree"
    return 0
  fi
  head="$(git rev-parse HEAD)"
  # The host's last built commit may be another slot's; bring its objects here so the clean rules
  # can diff against it (nightly_build_state.py). A failed fetch only means a clean build.
  if git -C "$root/src" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    git -c core.hooksPath=/dev/null fetch -q --no-tags "$root/src" "+HEAD:refs/nightly-host/last-built" 2>/dev/null || true
  fi
  if env -u GITHUB_ENV CMUX_CI_CANONICAL_ROOT="$root" scripts/ci/canonical-build-root.sh "$workspace" >&2 \
    && [[ "$(git -C "$root/src" rev-parse HEAD 2>/dev/null)" == "$head" ]] \
    && python3 scripts/ci/nightly_build_state.py prepare-host "$root"; then
    # shellcheck disable=SC2034 # read by app-build-release.sh
    host_root="$root"
    build_root="$root/src"
    derived_data="$root/DerivedData"
    # Each slot's checkout has its own file times: compare contents (release-compile-fleet-cas.sh).
    export XCBUILD_FILE_SYSTEM_MODE=checksum-only
    if [[ "${CMUX_NEXT_ACPMUX_BIN:-}" == "$workspace/"* ]]; then
      export CMUX_NEXT_ACPMUX_BIN="$build_root/${CMUX_NEXT_ACPMUX_BIN#"$workspace/"}"
    fi
    # A relative cache root stays the workspace's, which the cache save step reads.
    if [[ -n "${CMUX_NEXT_OPTCHAT_CHIEF_CACHE:-}" && "$CMUX_NEXT_OPTCHAT_CHIEF_CACHE" != /* ]]; then
      export CMUX_NEXT_OPTCHAT_CHIEF_CACHE="$workspace/$CMUX_NEXT_OPTCHAT_CHIEF_CACHE"
    fi
    echo "nightly host build root: building $head in $build_root into $derived_data"
  else
    exec 9>&-
    echo "::warning title=nightly host build root::setting up $root failed; building in this slot's own tree"
  fi
}
nightly_host_root_take
