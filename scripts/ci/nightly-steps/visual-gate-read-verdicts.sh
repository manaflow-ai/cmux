#!/usr/bin/env bash
# nightly.yml find-nightly-next-recovery: "Read the visual gate's verdicts". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# A recovered build is judged by the visual gate's verdict on that build,
# recorded in the gate's issue by the run that built it, never by this
# run's own gate: in enforce mode the continuation refuses a build the
# gate failed (scripts/ci/nightly_next_canary_mode.py admit).
# A bad gate variable never stops a recovery, and never admits a build
# the gate recorded as failed: it is read as enforce, which refuses only
# a recorded `fail`.
set -euo pipefail
if ! resolved="$(python3 scripts/ci/nightly_next_canary_mode.py resolve --variable NIGHTLY_NEXT_VISUAL_GATE \
  --default-enforce-after 2026-10-28T16:00:00Z --gate "visual gate" \
  --issue-title "nightly-next visual gate" --failure-prefix "cmux NEXT visual gate failed " \
  --pass-prefix "cmux NEXT visual gate passed " --min-passes 3)"; then
  echo "::warning title=nightly-next visual gate::could not resolve the gate's mode; a recovered build the gate failed is refused, any other is admitted"
  resolved="mode=enforce"
fi
echo "$resolved" | tee -a "$GITHUB_OUTPUT"
verdicts="$(python3 scripts/ci/nightly_next_canary_mode.py verdicts --issue-title "nightly-next visual gate" \
  --pass-prefix "cmux NEXT visual gate passed " --failure-prefix "cmux NEXT visual gate failed ")"
echo "verdicts=$verdicts" >> "$GITHUB_OUTPUT"
