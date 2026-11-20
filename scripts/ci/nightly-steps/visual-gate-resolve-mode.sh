#!/usr/bin/env bash
# nightly.yml route-visual-gate-nightly: "Resolve the visual gate mode". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# The gate reports configuration failures, but visual coverage is advisory and
# cannot hold publication. Set the variable to report, enforce, off or auto to
# choose coverage; signing and provenance checks remain publication gates.
set -e  # the inline step ran under bash -e
set -uo pipefail
if resolved="$(python3 scripts/ci/nightly_next_canary_mode.py resolve --variable NIGHTLY_NEXT_VISUAL_GATE \
  --enforce-after never --default-enforce-after never --gate "visual gate" \
  --issue-title "nightly-next visual gate" --failure-prefix "cmux NEXT visual gate failed " \
  --pass-prefix "cmux NEXT visual gate passed " --min-passes 3)"; then
  echo "$resolved" | tee -a "$GITHUB_OUTPUT"
else
  why="the gate's mode could not be resolved (NIGHTLY_NEXT_VISUAL_GATE=${NIGHTLY_NEXT_VISUAL_GATE:-unset})"
  { echo "mode=invalid"; echo "why=$why"; } | tee -a "$GITHUB_OUTPUT"
  echo "::error title=nightly-next visual gate::$why; visual coverage is advisory and publication is unaffected. Set it to report, enforce, off or auto."
  printf '## Nightly visual gate\n\nMode `invalid`: %s. Visual coverage is advisory; publication is unaffected.\n' "$why" >> "$GITHUB_STEP_SUMMARY"
fi
