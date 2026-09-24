#!/usr/bin/env bash
# canonical-build-root.sh [workspace]
#
# Put the build somewhere every macOS runner pool can name identically.
#
# Xcode's compilation cache keys each entry on the compiler invocation, which
# carries absolute source and derived-data paths. Runner pools disagree about
# those paths -- Blacksmith checks out under /Users/runner/_work, WarpBuild
# under /Users/runner/work -- so a cache seeded on one pool cannot hit on the
# other. scripts/ci/compile-app-host-test-product.sh therefore folds the paths
# into its cache key, which turns the disagreement into a permanent miss
# instead of a wrong hit.
#
# This removes the disagreement at the source: the build runs from
# $CMUX_CI_CANONICAL_ROOT/src, a constant, so the key can drop the paths and
# one seed serves every pool.
#
# A symlink will not do. The compiler records the path it actually opens, and
# a link back into the workspace resolves to the pool-specific path again, so
# the entries would still disagree while the key claimed they matched -- the
# one outcome worse than today, because it downloads a seed that cannot hit.
# The copy is what makes the path real. It costs one local file copy against a
# compile measured at ~18 minutes.
set -euo pipefail

root="${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}"
src="$root/src"
runtime_source=false
if [ "${1:-}" = --runtime-source ]; then
  runtime_source=true
  shift
fi
workspace="${1:-${GITHUB_WORKSPACE:-$PWD}}"

if [ ! -d "$workspace" ]; then
  echo "canonical-build-root: workspace $workspace does not exist" >&2
  exit 1
fi

case "$root" in
  /*) ;;
  *)
    echo "canonical-build-root: root must be absolute, got $root" >&2
    exit 1
    ;;
esac

# The root must not sit inside the workspace: copying a directory into itself
# recurses, and the paths would be pool-specific again.
case "$root/" in
  "$workspace"/*)
    echo "canonical-build-root: root $root must live outside the workspace" >&2
    exit 1
    ;;
esac

mkdir -p "$root"

# Test binaries embed #filePath strings which xctestrun relocation cannot edit.
# Consumers only need the source files at that path, not another checkout copy.
# A later producer removes this alias below before building a real source tree.
if [ "$runtime_source" = true ]; then
  case "$workspace/" in
    "$src/"*)
      echo "canonical-build-root: runtime workspace must live outside $src" >&2
      exit 1
      ;;
  esac
  rm -rf "$src"
  ln -s "$workspace" "$src"
  exit 0
fi

# Self-hosted runners reuse disks, so an earlier job's tree may still be here.
# Refuse to reuse a stale one: a partial copy compiles the wrong sources, and
# a symlink left by an older revision of this script defeats the whole point.
if [ -L "$src" ]; then
  rm -f "$src"
elif [ -e "$src" ] && [ ! -d "$src" ]; then
  rm -f "$src"
fi

# --delete makes the copy exact, so a file deleted in the branch cannot
# survive from a previous job and compile into the product. .git comes along
# because the product receipt stamps `git rev-parse HEAD` from the build tree.
mkdir -p "$src"
rsync -a --delete "$workspace"/ "$src"/

if [ ! -d "$src/.git" ] && [ ! -f "$src/.git" ]; then
  echo "canonical-build-root: copied tree has no .git; product stamping needs it" >&2
  exit 1
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "CMUX_CI_CANONICAL_ROOT=$root"
    echo "CMUX_CI_CANONICAL_SRC=$src"
  } >> "$GITHUB_ENV"
fi

echo "canonical build root ready: $src"
