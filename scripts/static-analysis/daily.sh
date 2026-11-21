#!/usr/bin/env bash
# the daily static-analysis run: osv-scanner, cargo-deny, cargo-machete and knip over the
# tree, then one issue per finding that is new since the baseline (daily_findings.py).
# Report-only: no pull request check runs it or reads it.
#
#   bash scripts/static-analysis/daily.sh            print what would be filed
#   SA_FILE=1 GITHUB_TOKEN=... bash .../daily.sh     file the issues (the daily workflow)
#
# Stop conditions: at most SA_MAX_NEW (10) issues per run, the rest on later runs; a tool that
# could not run fails the run after the others' findings are filed. The workflow's
# timeout-minutes bounds the whole run.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)" || exit 2
export FAST_CHECKS_OUT="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
start=$(date +%s)

SA_ONLY="osv-scanner cargo-deny cargo-machete knip" bash "$here/run-all.sh"
tools_status=$?

args=("$FAST_CHECKS_OUT" --root "$root" --baseline "$here/daily-baseline.txt" --max-new "${SA_MAX_NEW:-10}"
      --run-url "${SA_RUN_URL:-}" --sha "$(git -C "$root" rev-parse HEAD)")
[ "${SA_FILE:-0}" = 1 ] && args+=(--file)
python3 -I "$here/daily_findings.py" "${args[@]}"
filer_status=$?

echo "SA_DAILY seconds=$(( $(date +%s) - start )) tools_status=$tools_status filer_status=$filer_status"
[ "$filer_status" -ne 0 ] && exit "$filer_status"
exit "$tools_status"
