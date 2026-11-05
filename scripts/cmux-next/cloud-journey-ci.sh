#!/usr/bin/env bash
# The Cloud journey in CI (backend.yml journey-* jobs, cmux-platform's deploys): TARGET is a
# cloud-journey.ts --backend name (preview-N, staging, prod). Runs it as the agent test account's own
# team, then as PRODUCT_TEAM when set (the never-pause path a product team takes), and writes each
# run's step table to the job summary. No agent test account in this environment: a notice, exit 0.
#
# Around a deploy (cmux-vm.yml): JOURNEY_PHASE=baseline before it (never fails the job), then
# JOURNEY_PHASE=after: exit 3 when a step that passed on the baseline fails now (the deploy's own red,
# which rolls the Worker back), 1 for a red that was already red before, 0 when green.
set -euo pipefail
: "${TARGET:?TARGET is a cloud-journey.ts --backend name}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${RUNNER_TEMP:-$(mktemp -d)}/cloud-journey"
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
if [ -z "${CMUX_DOGFOOD_STACK_EMAIL:-}" ] || [ -z "${CMUX_DOGFOOD_STACK_PASSWORD:-}" ]; then
  echo "::notice title=Cloud journey not run::this job's environment holds no agent test account (CMUX_*_STACK_EMAIL/_PASSWORD)"
  printf 'Cloud journey on `%s` not run: no agent test account in this environment.\n' "$TARGET" >> "$summary"
  exit 0
fi
phase="${JOURNEY_PHASE:-}"
status=0
regressed=0
run() { # label, extra args...
  local label="$1"; shift
  local dir="$out/${phase:+$phase-}$label"
  mkdir -p "$dir"
  local args=(--backend "$TARGET" --out "$dir")
  # The credentialed staging job supplies a Linux cmux-tui so the link path is exercised.
  # Keep the existing sync skip for app-less jobs, and let the caller select the model used
  # by the guest chat (the staging smoke uses the local model stub, never a real credential).
  if [ -n "${CMUX_PATH:-}" ]; then args+=(--cmux "$CMUX_PATH"); else args+=(--skip sync); fi
  if [ -n "${JOURNEY_MODEL:-}" ]; then args+=(--model "$JOURNEY_MODEL"); fi
  if bun "$here/cloud-journey.ts" "${args[@]}" "$@"; then :; else status=1; fi
  { printf '### %s%s\n\n' "${phase:+$phase: }" "$label"; cat "$dir/summary.md" 2>/dev/null || echo "(no summary written)"; echo; } >> "$summary"
  if [ "$phase" = after ]; then
    # Only exit 3 is a proven green-to-red step; any other nonzero exit is the compare itself failing,
    # which is reported and never rolls the Worker back.
    local rc=0
    bun "$here/cloud-journey.ts" --compare "$out/baseline-$label/journey.json" "$dir/journey.json" > "$dir/compare.txt" 2>&1 || rc=$?
    cat "$dir/compare.txt" >> "$summary"
    if [ "$rc" = 3 ]; then regressed=1; elif [ "$rc" != 0 ]; then echo "::warning title=Cloud journey::compare failed (exit $rc); not rolling back"; fi
  fi
}
run test-team
if [ -n "${PRODUCT_TEAM:-}" ]; then
  run product-team --team "$PRODUCT_TEAM"
fi
if [ "$phase" = baseline ]; then exit 0; fi
if [ "$regressed" = 1 ]; then exit 3; fi
exit "$status"
