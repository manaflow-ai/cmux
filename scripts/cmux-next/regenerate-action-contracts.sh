#!/usr/bin/env bash
# Regenerate the checked-in cmux-next action contract exports.
#
# ActionSurfaceParityTests owns the generated JSON export and the generated
# block in plans/cmux-next/actions.md. ActionCatalogTests and the inventory
# checks are source-backed parity tests and run in the same command when CI
# validates the result.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
package_root="${1:-$repo_root/Packages/macOS/CmuxNext}"
cd "$package_root"

CMUX_UPDATE_ACTION_SURFACES=1 \
  swift test --skip-build --filter ActionSurfaceParityTests
