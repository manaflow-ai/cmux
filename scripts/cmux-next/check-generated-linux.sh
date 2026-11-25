#!/usr/bin/env bash
# check-action-surfaces.sh's export checks, off the Mac: the committed action exports
# (action-surfaces.json, actions.md's generated block) and links.json equal a fresh export from the
# Rust catalog at the app-ffi-pin.json commit and the deep link sources. The catalog's invariants are
# tested where they live: cmux-action-catalog's own tests (swift_parity, action_contract) in the Rust
# CI against HEAD's crate, and the Swift suites (ActionContractTests, ActionCatalogTests,
# CLISurfaceParityTests, ActionSurfaceParityTests, which also compares the committed export with
# Swift's) in the swift-test job whenever their targets route there. judge-action-exports.sh runs this as
# CMUX_ACTION_EXPORTS_CHECK in the Linux generated-files job (cmux-next.yml generated-files-linux).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
"$here/export-action-surfaces-linux.sh" --check --only surfaces || status=1
"$here/export-settings-links-linux.sh" --check --only links || status=1
exit "$status"
