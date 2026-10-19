#!/usr/bin/env bash
# canonical-build-root.sh [workspace]
# canonical-build-root.sh --print-root
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
# $CMUX_CI_CANONICAL_ROOT/src, a stable path for the runner. Self-hosted
# runners without glaeda derive that root from RUNNER_NAME so concurrent
# runners on one Mac do not delete each other's source tree, DerivedData, or
# compilation CAS; glaeda-managed Macs keep the per-job root their hook
# exports. The cache fingerprint includes a non-default root, so a seed from
# another runner's absolute path is never adopted.
#
# A symlink will not do. The compiler records the path it actually opens, and
# a link back into the workspace resolves to the pool-specific path again, so
# the entries would still disagree while the key claimed they matched -- the
# one outcome worse than today, because it downloads a seed that cannot hit.
# The copy is what makes the path real. It costs one local file copy against a
# compile measured at ~18 minutes.
set -euo pipefail

default_root=/private/tmp/cmux-ci
# A glaeda-managed Mac already isolates roots per job: its runner hook exports
# CMUX_CI_CANONICAL_ROOT (the default for root 1, /private/tmp/cmux-ci-N
# otherwise) and `glaeda-canonical-root take` rejects any other path, so keep
# the hook's root there instead of deriving one from RUNNER_NAME.
# Only a fleet Mac without glaeda (several runners sharing one disk) needs a
# per-runner root. Ephemeral runners such as Blacksmith also report
# self-hosted, but run one job per VM; a per-runner root there would start
# every build cold and make its seeds unadoptable.
glaeda_helper="${CMUX_CI_CANONICAL_ROOT_HELPER:-/Users/Shared/cmux-build-fleet/bin/glaeda-canonical-root}"
fleet_dir="${CMUX_CI_FLEET_DIR:-/Users/Shared/cmux-build-fleet}"
if [ "${RUNNER_ENVIRONMENT:-}" = self-hosted ] \
  && [ -n "${RUNNER_NAME:-}" ] \
  && [ -d "$fleet_dir" ] \
  && [ ! -x "$glaeda_helper" ] \
  && [ "${CMUX_CI_CANONICAL_ROOT:-$default_root}" = "$default_root" ]; then
  runner_key="$(printf '%s' "$RUNNER_NAME" | tr -c 'A-Za-z0-9_.-' '_')"
  root="$default_root-$runner_key"
elif [ -n "${CMUX_CI_CANONICAL_ROOT:-}" ]; then
  root="$CMUX_CI_CANONICAL_ROOT"
else
  root="$default_root"
fi

if [ "${1:-}" = --print-root ]; then
  printf '%s\n' "$root"
  exit 0
fi

src="$root/src"
runtime_source=false
if [ "${1:-}" = --runtime-source ]; then
  runtime_source=true
  shift
fi
workspace="${1:-${GITHUB_WORKSPACE:-$PWD}}"
runtime_root="${CMUX_CI_RUNTIME_SOURCE_ROOT:-$root}"
runtime_src="$runtime_root/src"

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
    "$runtime_src/"*)
      echo "canonical-build-root: runtime workspace must live outside $runtime_src" >&2
      exit 1
      ;;
  esac
  mkdir -p "$runtime_root"
  rm -rf "$runtime_src"
  ln -s "$workspace" "$runtime_src"
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

# The copy must be exact, so a file deleted in the branch cannot survive from a
# previous job and compile into the product; the old tree is removed first.
# .git comes along because the product receipt stamps `git rev-parse HEAD`
# from the build tree.
#
# The copy is an APFS clone (`cp -c`), which shares blocks instead of writing
# them: 8 s against openrsync's 32 s for a 483 MB checkout on an M-series Mac,
# and openrsync also truncates modification times to whole seconds. A volume
# without clone support falls back to rsync.
#
# CMUX_CI_MOVE_SOURCE_PACKAGES=1 moves the restored .ci-source-packages
# instead of copying it: it is most of the bytes, and a caller that never reads
# the workspace copy again (ci-macos.yml compile admission) should not pay for
# it twice. It is set aside under the root before the clone and moved into the
# fresh tree after, so an earlier job's packages cannot survive either.
move_packages=false
if [ "${CMUX_CI_MOVE_SOURCE_PACKAGES:-}" = 1 ]; then
  move_packages=true
fi
incoming="$root/.ci-source-packages.incoming"
rm -rf "$incoming"
if [ "$move_packages" = true ] && { [ -e "$workspace/.ci-source-packages" ] || [ -L "$workspace/.ci-source-packages" ]; }; then
  mv "$workspace/.ci-source-packages" "$incoming"
fi
rm -rf "$src"
# One clonefile(2) of the whole tree first: about a tenth of cp's per-file
# clone time (scripts/ci/apfs_clone.py). Directories then carry the copy's
# time instead of the checkout's, which the seed replay restores where it
# matters.
if python3 "$(dirname "${BASH_SOURCE[0]}")/apfs_clone.py" "$workspace" "$src"; then
  :
elif ! clone_error="$(cp -cpR "$workspace"/. "$src" 2>&1)"; then
  echo "canonical-build-root: clone failed (${clone_error%%$'\n'*}); copying with rsync" >&2
  rm -rf "$src"
  mkdir -p "$src"
  rsync -a --delete "$workspace"/ "$src"/
fi
if [ "$move_packages" = true ]; then
  rm -rf "$src/.ci-source-packages"
  if [ -e "$incoming" ] || [ -L "$incoming" ]; then
    mv "$incoming" "$src/.ci-source-packages"
  fi
fi

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
