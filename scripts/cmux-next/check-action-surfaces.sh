#!/usr/bin/env bash
# Fails when an action lacks a surface without a reasoned exemption
# (plans/cmux-next/actions.md): every action declares whether the command
# palette, the `cmux` CLI, a right-click menu and MCP offer it, or names a
# SurfaceExemption. Runs the exhaustive catalog checks:
#   ActionSurfaceParityTests  every surface declared, menus generated from
#                             placements, each target kind's menu complete,
#                             menu items run their own action, export fresh
#   ActionContractTests       unique CLI names and shortcuts, menus resolve
#   ActionCatalogTests        catalog IDs and inventory domain counts
#   CLISurfaceParityTests     every CLI verb runs its own handler by name
#
# This check deliberately runs without CMUX_UPDATE_ACTION_SURFACES. CI must
# inspect the committed exports rather than rewriting them and hiding drift.
# Usage: scripts/cmux-next/check-action-surfaces.sh [package-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
cd "$root"
exec swift test -j "${CMUX_NEXT_SWIFT_JOBS:-4}" \
  --filter 'ActionSurfaceParityTests|ActionCatalogTests|ActionContractTests|CLISurfaceParityTests'
