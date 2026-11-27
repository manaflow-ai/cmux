#!/usr/bin/env bash
# nightly.yml verify-nightly-identity-legacy: "Check out the build's own source for the bundle checks". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The license check compares the app with its own source tree, as in the
# signing job: the copied build can be older than this run's commit.
set -euo pipefail
[[ "$BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid build commit '$BUILD_SHA'" >&2; exit 1; }
# A depth flag only in an already-shallow checkout: in a full clone it would make every worktree shallow.
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
git fetch --no-tags ${depth[@]+"${depth[@]}"} origin "$BUILD_SHA"
# An owned Mac keeps its workspace between jobs while the runner empties RUNNER_TEMP, so an
# earlier job's build-src can still be registered there: drop registrations whose folder is gone.
git worktree prune
git worktree add --detach "$RUNNER_TEMP/build-src" "$BUILD_SHA"
(cd "$RUNNER_TEMP/build-src" && bash scripts/ci/init-submodule.sh ghostty-next)
echo "CMUX_VERIFY_LICENSES_TOOL=$RUNNER_TEMP/build-src/scripts/verify-app-bundle-licenses.sh" >> "$GITHUB_ENV"
