#!/usr/bin/env bash
# Regenerates the action exports (plans/cmux-next/action-surfaces.json,
# actions.md and links.json) for the autofix bots, on a Mac runner, and copies
# the ones that changed into OUT at their repository paths: the --generated
# DIR of scripts/cmux-next/base-autofix.sh, which copies them over the
# checkout before it regenerates the docs shortcuts from the new catalog.
# Rust (cmux-tui include_str!), the docs and gen-cmux-global.ts read the
# committed copy, so the exports stay checked in; no person regenerates them.
#
# Usage: scripts/cmux-next/regenerate-action-exports.sh OUT
set -euo pipefail
# swift test builds and runs cmux-next's test host: fleet or GitHub runner only.
# shellcheck source-path=SCRIPTDIR source=lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-only.sh"
cmux_next_require_fleet regenerate-action-exports.sh "swift test" "cmux-next PR autofix / action exports"
out="$(mkdir -p "${1:?usage: $0 OUT}" && cd "$1" && pwd)"
root="$(git rev-parse --show-toplevel)"
exports=(plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md plans/cmux-next/links.json)

cd "$root/Packages/macOS/CmuxNext"
swift build --build-tests
# The exports are written before each test compares them, so a parity test
# that fails for another reason still leaves them current; that failure is
# the pull request's to fix, not the autofix's.
status=0
CMUX_UPDATE_ACTION_SURFACES=1 swift test --skip-build --filter 'ActionSurfaceParityTests|LinkExportTests' || status=$?
(( status == 0 )) || echo "::warning::the action parity tests failed (exit $status); the exports were still regenerated"
cd "$root"
for file in "${exports[@]}"; do
  git diff --quiet -- "$file" && continue
  mkdir -p "$out/$(dirname "$file")"
  cp "$file" "$out/$file"
  echo "regenerated: $file"
done
