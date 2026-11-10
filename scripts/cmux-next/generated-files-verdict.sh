#!/usr/bin/env bash
# The generated files verdict, from cmux-next.yml's two checks: one script for every job that checks
# the generated files, so the copies cannot drift.
#   ACTIONS   the `actions` step's outcome (judge-action-exports.sh)
#   CATALOG   `failure` when the action checks fail with fresh exports too: a catalog failure, not
#             stale files (2026-10-29: #27632's "stale" label sent a fix the wrong way)
#   SETTINGS  the `settings` step's outcome (check-settings-exports.sh)
# Writes `verdict=fresh|stale|catalog|` to GITHUB_OUTPUT (empty: the build failed or the checks never
# ran, which generated-verdict fails) and says why in the step summary.
# A job that folds the checks into its own build (swift-test, daemon-test, fast-tier) only reports the
# verdict: generated-verdict reads it, so a stale file never turns that job red and its red never hides
# a stale file. With --fail (the generated-files job) a stale or catalog verdict fails the step.
# Usage: scripts/cmux-next/generated-files-verdict.sh [--fail]
set -uo pipefail
ACTIONS="${ACTIONS:-}" CATALOG="${CATALOG:-}" SETTINGS="${SETTINGS:-}"
if [[ "$ACTIONS" == failure && "$CATALOG" == failure ]]; then
  verdict=catalog
  {
    echo "### The action catalog checks fail: a catalog failure, not stale files"
    echo
    echo "Fresh exports fail the same checks, so regenerating changes nothing. The step \"Check generated action catalog, surfaces and inventory\" names the failing test."
    [[ "$SETTINGS" != failure ]] || echo "- settings exports are also stale: scripts/cmux-next/regenerate-settings-exports.sh"
  } | tee -a "$GITHUB_STEP_SUMMARY"
elif [[ "$ACTIONS" == failure || "$SETTINGS" == failure ]]; then
  verdict=stale
  {
    echo "### Generated cmux-next files are stale"
    echo
    [[ "$ACTIONS" != failure ]] || echo "- action catalog, surfaces or inventory: scripts/cmux-next/regenerate-action-contracts.sh"
    [[ "$SETTINGS" != failure ]] || echo "- settings exports: scripts/cmux-next/regenerate-settings-exports.sh"
    echo
    echo "The cmux-next-generated-patch artifact holds the regenerated files at their repository paths."
  } | tee -a "$GITHUB_STEP_SUMMARY"
elif [[ "$ACTIONS" == success && "$SETTINGS" == success ]]; then
  verdict=fresh
else
  verdict=
fi
echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
[[ "${1:-}" == --fail ]] || exit 0
case "$verdict" in
  catalog)
    echo "::error::The action catalog checks fail with fresh exports too: a catalog failure, not stale files."
    exit 1 ;;
  stale)
    echo "::error::Generated cmux-next files are stale. Regenerate them as the step summary says."
    exit 1 ;;
esac
