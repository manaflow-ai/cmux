#!/usr/bin/env bash
# The Cloud journey in CI (backend.yml journey-* jobs, cmux-platform's deploys): TARGET is a
# cloud-journey.ts --backend name (preview-N, staging, prod). Runs it as the agent test account's own
# team, then as PRODUCT_TEAM when set (the never-pause path a product team takes), and writes each
# run's step table to the job summary. No agent test account in this environment: a notice, exit 0.
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
status=0
run() { # label, extra args...
  local label="$1"; shift
  local dir="$out/$label"
  mkdir -p "$dir"
  if bun "$here/cloud-journey.ts" --backend "$TARGET" --out "$dir" "$@"; then :; else status=1; fi
  { printf '### %s\n\n' "$label"; cat "$dir/summary.md" 2>/dev/null || echo "(no summary written)"; echo; } >> "$summary"
}
run test-team
if [ -n "${PRODUCT_TEAM:-}" ]; then
  run product-team --team "$PRODUCT_TEAM"
fi
exit "$status"
