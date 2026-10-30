#!/usr/bin/env bash
# nightly.yml route-visual-gate-nightly: "Resolve the visual gate mode". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# The gate fails closed on its own configuration: a resolver that fails
# (an invalid NIGHTLY_NEXT_VISUAL_GATE, a crash) gives the mode
# `invalid`, which runs no gate and holds this run's own build in
# publish-nightly. Set the variable to report, enforce, off or auto to
# publish again.
set -e  # the inline step ran under bash -e
set -uo pipefail
if resolved="$(python3 scripts/ci/nightly_next_canary_mode.py resolve --variable NIGHTLY_NEXT_VISUAL_GATE \
  --default-enforce-after 2026-10-28T16:00:00Z --gate "visual gate" \
  --issue-title "nightly-next visual gate" --failure-prefix "cmux NEXT visual gate failed " \
  --pass-prefix "cmux NEXT visual gate passed " --min-passes 3)"; then
  echo "$resolved" | tee -a "$GITHUB_OUTPUT"
else
  why="the gate's mode could not be resolved (NIGHTLY_NEXT_VISUAL_GATE=${NIGHTLY_NEXT_VISUAL_GATE:-unset})"
  { echo "mode=invalid"; echo "why=$why"; } | tee -a "$GITHUB_OUTPUT"
  echo "::error title=nightly-next visual gate::$why; this run's build is not published. Set it to report, enforce, off or auto."
  printf '## Nightly visual gate\n\nMode `invalid`: %s. This run'"'"'s build is not published.\n' "$why" >> "$GITHUB_STEP_SUMMARY"
fi
