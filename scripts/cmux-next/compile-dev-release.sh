#!/usr/bin/env bash
# Compile the cmux NEXT DEV Release app and zip it to ARCHIVE (cmux-next.yml,
# "Compile the cmux NEXT DEV Release app"; the step's env sets the build).
#
# Its warm state is Xcode's compilation cache (lib/compilation-cache.sh). The
# cache's keys hold the absolute source and DerivedData paths, and a runner's
# own paths (its workspace, its RUNNER_NAME DerivedData) made one cache per
# runner instance. The DEV compile lands on 30+ of them (cmuxNN-glaeda-K), so
# every compile was cold. On a mini with the cache on, this builds from ONE
# tree per host instead, HOST_ROOT/src, into one DerivedData per host
# (release-derived-data-path.sh --host), so the keys match whichever instance
# builds:
#
# - The tree is this checkout, cloned whole by canonical-build-root.sh, as the
#   owned catch-up and compile admission build at a fixed root: the old tree is
#   removed first (no file from an earlier build survives), the copy is an APFS
#   clone with an rsync fallback, and it carries .git and the products earlier
#   steps put in the checkout (the cmux-tui tree, the web bundles).
# - Only the CAS and SourcePackages carry over in the DerivedData
#   (check-cmux-scheme-compile.sh starts a cache build from an empty tree
#   around them; kept build products linked stale objects, #21761).
# - Two instances on a host never build there at once: host_build_lock.py
#   takes flock(2) on HOST_ROOT/lock through fd 9, without waiting. Every child
#   (the clone, xcodebuild, ditto) inherits fd 9, so the kernel holds the lock
#   until the last of them exits, however this script ends (SIGKILL included),
#   and no lock outlives them.
#
# A busy lock, a lock error or a failed tree setup builds the old way at once,
# per runner instance from the checkout (release-derived-data-path.sh, still
# with the cache). Nothing waits for another job and no host is reserved.
#
# Usage: compile-dev-release.sh ARCHIVE
set -euo pipefail

archive="${1:?usage: compile-dev-release.sh ARCHIVE}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace="$(cd "$here/../.." && pwd -P)"
host_root="${HOME:?}/Library/Caches/cmux-next-ci/dev-daily-release/host"
lock="$host_root/lock"

# Closing this script's fd 9 drops its share of the lock; a child still running
# keeps it until it exits.
release_lock() { exec 9>&-; }
trap 'exit 143' TERM INT HUP

build_root="$workspace"
derived_data=""
mode=instance
reason=""

# The host tree for this commit, or a failure (the caller falls back).
host_setup() {
  local src="$host_root/src" head
  head="$(git -C "$workspace" rev-parse HEAD)" || return 1
  env -u GITHUB_ENV CMUX_CI_CANONICAL_ROOT="$host_root" \
    "$workspace/scripts/ci/canonical-build-root.sh" "$workspace" >&2 || return 1
  [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" == "$head" ]] || {
    echo "compile-dev-release: $src is not at $head after the clone" >&2
    return 1
  }
  derived_data="$("$here/release-derived-data-path.sh" dev-daily-release Release --host)" || return 1
  build_root="$src"
}

if [[ "${CMUX_NEXT_RUNNER:-}" != glaeda-* ]]; then
  reason="not a mini"
elif [[ "${CMUX_NEXT_COMPILATION_CACHE:-0}" != 1 ]]; then
  reason="compilation cache off"
else
  lock_status=0
  { mkdir -p "$host_root" && exec 9>>"$lock" && python3 -I "$here/host_build_lock.py" acquire "$lock" --fd 9; } \
    || lock_status=$?
  (( lock_status == 0 )) || release_lock 2>/dev/null || true
  case "$lock_status" in
    0)
      if host_setup; then
        mode=host
      else
        reason="host tree setup failed"
        derived_data=""
        build_root="$workspace"
        release_lock
      fi
      ;;
    1) reason="another build holds the host root" ;;
    *) reason="host lock error ($lock_status)" ;;
  esac
fi

if [[ "$mode" == host ]]; then
  # The acpmux the bundle phase copies, from this tree when it came from the checkout.
  if [[ "${CMUX_NEXT_ACPMUX_BIN:-}" == "$workspace/"* ]]; then
    export CMUX_NEXT_ACPMUX_BIN="$build_root/${CMUX_NEXT_ACPMUX_BIN#"$workspace/"}"
  fi
else
  derived_data="$("$here/release-derived-data-path.sh" dev-daily-release Release)"
fi
echo "compile-dev-release: $mode build root${reason:+ ($reason)}: $build_root, DerivedData $derived_data"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "DEV Release compile: $mode build root${reason:+ ($reason)}" >> "$GITHUB_STEP_SUMMARY" || true
fi

"$build_root/scripts/cmux-next/check-cmux-scheme-compile.sh" "$derived_data"
app="$(find "$derived_data/Build/Products/Release" -maxdepth 1 -type d -name 'cmux NEXT DEV.app' -print -quit)"
test -d "$app"
"$build_root/scripts/cmux-next/check-app-personalities.sh" "$app"
ditto -c -k --keepParent "$app" "$archive"
