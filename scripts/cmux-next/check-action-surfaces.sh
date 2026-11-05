#!/usr/bin/env bash
# Fails when an action lacks a surface without a reasoned exemption
# (plans/cmux-next/actions.md): every action declares whether the command
# palette, the `cmux` CLI, a right-click menu and MCP offer it, or names a
# SurfaceExemption. Runs the exhaustive catalog checks:
#   ActionSurfaceParityTests  every surface declared, menus generated from
#                             placements, each target kind's menu complete,
#                             menu items run their own action, export fresh
#   LinkExportTests           links.json fresh and true to the code
#   ActionContractTests       unique CLI names and shortcuts, menus resolve
#   ActionCatalogTests        catalog IDs and inventory domain counts
#   CLISurfaceParityTests     every CLI verb runs its own handler by name
#   ActionArgumentContractTests  argument names canonical (camelCase), exported, old spellings fold
#
# This check deliberately runs without CMUX_UPDATE_ACTION_SURFACES. CI must
# inspect the committed exports rather than rewriting them and hiding drift.
# CMUX_CHECK_GENERATED_EXPORTS=1 turns the freshness tests on: other test runs
# skip them (feat-cmux-next's autofix bots regenerate the exports).
# Usage: scripts/cmux-next/check-action-surfaces.sh [package-root]
set -euo pipefail
# cmux-ci-warm-contract: swiftpm-v1
# swift test builds and runs cmux-next's test host: fleet or GitHub runner only.
# shellcheck source-path=SCRIPTDIR source=lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-only.sh"
cmux_next_require_fleet check-action-surfaces.sh "swift test" "cmux-next generated files" \
  "cmux-ci run --class light --script scripts/cmux-next/check-action-surfaces.sh"
# shellcheck source-path=SCRIPTDIR source=lib/warm-swiftpm.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/warm-swiftpm.sh"
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
cd "$root"
# Absolute from here: cmux_next_warm_build resolves it again, from this directory (a relative
# PACKAGE-ROOT would otherwise name a folder inside itself).
root="$PWD"
# CMUX_ACTION_SURFACES_SKIP_BUILD=1: the package and its tests are already built
# (the CI jobs run `swift build --build-tests` first), so swift test does not
# plan the whole graph again.
filter='ActionSurfaceParityTests|ActionCatalogTests|ActionContractTests|ActionArgumentContractTests|CLISurfaceParityTests|LinkExportTests'
if [[ "${CMUX_ACTION_SURFACES_SKIP_BUILD:-}" == 1 ]]; then
  CMUX_CHECK_GENERATED_EXPORTS=1 exec swift test -j "${CMUX_NEXT_SWIFT_JOBS:-4}" --skip-build --filter "$filter"
fi
# Otherwise build in place under the warm contract (lib/warm-swiftpm.sh), then test that build.
# The fleet grant (CMUX_CI_CPU_BUDGET, --jobs in the shared flags) wins over -j.
jobs=(-j "${CMUX_NEXT_SWIFT_JOBS:-4}")
[[ " ${cmux_next_swift_args[*]-} " != *" --jobs "* ]] || jobs=()
cmux_next_warm_build "$root" ${jobs[@]+"${jobs[@]}"}
CMUX_CHECK_GENERATED_EXPORTS=1 exec swift test ${cmux_next_swift_args[@]+"${cmux_next_swift_args[@]}"} ${jobs[@]+"${jobs[@]}"} --skip-build --filter "$filter"
