#!/usr/bin/env bash
# nightly.yml find-nightly-next-recovery: "Read the visual gate's verdicts". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# A recovered build may still expose the visual gate's recorded verdict for
# reporting, but visual coverage is advisory and never controls recovery.
# Signing, notarization, provenance and feed-order checks remain the recovery
# gates; a visual verdict (or a mode-resolution failure) cannot reject them.
set -euo pipefail
if ! resolved="$(python3 scripts/ci/nightly_next_canary_mode.py resolve --variable NIGHTLY_NEXT_VISUAL_GATE \
  --enforce-after never --default-enforce-after never --gate "visual gate" \
  --issue-title "nightly-next visual gate" --failure-prefix "cmux NEXT visual gate failed " \
  --pass-prefix "cmux NEXT visual gate passed " --min-passes 3)"; then
  echo "::warning title=nightly-next visual gate::could not resolve the gate's mode; visual coverage remains advisory for recovery"
  resolved="mode=report"
fi
echo "$resolved" | tee -a "$GITHUB_OUTPUT"
verdicts="$(python3 scripts/ci/nightly_next_canary_mode.py verdicts --issue-title "nightly-next visual gate" \
  --pass-prefix "cmux NEXT visual gate passed " --failure-prefix "cmux NEXT visual gate failed ")"
echo "verdicts=$verdicts" >> "$GITHUB_OUTPUT"
