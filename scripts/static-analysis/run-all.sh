#!/usr/bin/env bash
# Runs every report-only static analysis script in this directory and prints one
# table of findings and runtime. Reports only: it blocks nothing and exits 0 when
# every tool ran, whatever it found. Run it on the fleet, never on a person's Mac:
#
#   cmux-ci test -- bash scripts/static-analysis/run-all.sh
#
# SA_ONLY="ruff gitleaks" runs a subset; SA_SKIP (default "periphery", which
# builds a Swift toolchain on Linux) leaves tools out. Each tool's full report lands in
# ${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}/.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FAST_CHECKS_OUT="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
mkdir -p "$FAST_CHECKS_OUT"

rows=()
broken=0
for script in "$here"/*.sh; do
  name="$(basename "$script" .sh)"
  [[ "$name" == "run-all" ]] && continue
  if [[ -n "${SA_ONLY:-}" && " $SA_ONLY " != *" $name "* ]]; then
    continue
  fi
  if [[ -z "${SA_ONLY:-}" && " ${SA_SKIP-periphery} " == *" $name "* ]]; then
    continue
  fi
  echo "::group::$name"
  log="$FAST_CHECKS_OUT/$name.log"
  bash "$script" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  echo "::endgroup::"
  summary="$(grep '^SA_SUMMARY ' "$log" | tail -n 1)"
  if [[ "$status" -ne 0 || -z "$summary" ]]; then
    broken=1
    rows+=("| $name | did not run (exit $status) | - |")
    continue
  fi
  findings="$(sed -n 's/.* findings=\([^ ]*\).*/\1/p' <<<"$summary")"
  seconds="$(sed -n 's/.* seconds=\([^ ]*\).*/\1/p' <<<"$summary")"
  rows+=("| $name | $findings | $seconds |")
done

{
  echo "| tool | findings | seconds |"
  echo "| --- | --- | --- |"
  printf '%s\n' "${rows[@]}"
} | tee "$FAST_CHECKS_OUT/summary.md"

exit "$broken"
