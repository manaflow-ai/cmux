#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Start Release DerivedData empty". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The build's settings key the kept DerivedData (nightly_build_state.py BUILD_SETTINGS).
set -euo pipefail
# Every runner but one starts from an empty tree. An incremental
# build can keep stale autolink and force-load data in objects it
# did not recompile after the module graph changed, and those objects
# then link into the app. Warm state that stays: the compilation cache restored into it
# below (content-keyed, with explicit module dependencies in each
# key) and the Swift package checkouts in .spm-cache.
# The exception is the dedicated nightly-next builder, which runs only
# this build: nightly_build_state.py keeps its DerivedData and builds
# each tip on it, starting clean when the last build did not finish,
# the toolchain, a build setting, a lockfile or a submodule changed, a
# module- or link-shaping file (Package.swift, *.pbxproj, ...), an import
# or an #if changed, or every 10th build. Output `mode`: clean or incremental.
scripts/ci/clear-dirs.sh build-universal
mkdir -p build-universal
if [ "${DECIDE_TRACK}" = nightly-next ]; then
  # A trusted worker keeps only its package checkouts and its
  # content-keyed compilation cache on disk, and deletes the build
  # state that earlier revisions kept. Elsewhere NEXT restores no
  # compilation cache, so its build is fully cold.
  python3 scripts/ci/nightly_build_state.py prepare nightly-next
  exit 0
fi
case "${RUNNER_NAME:-}" in
  *-glaeda|*-glaeda-[0-9]*)
    # Earlier jobs linked build-universal to a tree kept per channel
    # and toolchain. Delete this channel's trees, so no later change
    # can link one back and they stop using disk. Another channel's
    # trees (for example cmux-nightly-rc-*) are not touched.
    # The name ends in the 64-digit toolchain hash (plus the suffix
    # clear-dirs.sh adds when a delete did not finish), so the match
    # never reaches another name with the same prefix. The
    # nightly-next track keeps its state under
    # ~/Library/Caches/cmux-nightly-next, which this never touches.
    shopt -s nullglob
    stale=()
    for tree in "$HOME"/Library/Developer/Xcode/DerivedData/cmux-nightly-${DECIDE_CHANNEL}-*; do
      if [[ "${tree##*/}" =~ ^cmux-nightly-${DECIDE_CHANNEL}-[0-9a-f]{64}(\.stale\..+)?$ ]]; then
        stale+=("$tree")
      fi
    done
    if [ "${#stale[@]}" -gt 0 ]; then
      scripts/ci/clear-dirs.sh "${stale[@]}"
    fi
    ;;
esac
