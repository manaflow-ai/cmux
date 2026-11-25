#!/usr/bin/env bash
# check-action-surfaces.sh's export checks, off the Mac: the committed action exports (action-surfaces.json,
# action-catalog.json, actions.md's generated block, links.json) equal a fresh export by
# regenerate-action-exports-linux.sh (CmuxNextActions' own export code built on Linux against
# cmux-action-catalog at the app-ffi-pin.json commit). The catalog's invariants are tested where they live:
# cmux-action-catalog's tests in the Rust CI, and the Swift suites (ActionContractTests, ActionCatalogTests,
# CLISurfaceParityTests, ActionSurfaceParityTests) in the swift-test job whenever their targets route there.
# judge-action-exports.sh runs this as CMUX_ACTION_EXPORTS_CHECK in the Linux generated-files job
# (cmux-next.yml generated-files-linux). The checkout is put back: a check writes nothing.
# Exit 0 fresh, 1 stale, 2 the export could not run.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(git rev-parse --show-toplevel)"
exports=(plans/cmux-next/action-surfaces.json plans/cmux-next/action-catalog.json plans/cmux-next/actions.md plans/cmux-next/links.json)
temp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/generated-check.XXXXXX")"
trap 'git checkout -q HEAD -- "${exports[@]}" 2>/dev/null || true; rm -rf "$temp" "$temp.patch"' EXIT
"$here/regenerate-action-exports-linux.sh" "$temp/out" > "$temp/log" 2>&1 || { cat "$temp/log" >&2; exit 2; }
stale="$(sed -n 's/^regenerated: //p' "$temp/log")"
[[ -z "$stale" ]] || { sed 's/^/stale: /' <<<"$stale" >&2; exit 1; }
