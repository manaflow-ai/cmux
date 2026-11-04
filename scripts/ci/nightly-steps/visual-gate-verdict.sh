#!/usr/bin/env bash
# nightly.yml visual-gate-nightly: "Run the visual gate". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# visual_gate.py exits 0 (every state passed), 1 (a check failed: the
# build's fault), 3 (a state could not be judged) or 2 (bad input or a
# crash). Only 1 is `fail`; a gate that could not judge is
# `unavailable`, never a build failure. --states fails each state file
# with no capture folder (a state the capture never reached), so a
# capture cut off by a timeout or a cancel is `unavailable` instead.
#
# The step's notes, moved from nightly.yml:
# 1 once the capture Macs draw at 2x (a HiDPI display): stills below 2x then fail.
set -e  # the inline step ran under bash -e
set -uo pipefail
states=("$RUNNER_TEMP"/visual-gate/*/)
if [ ! -d "${states[0]}" ] || [ "${CAPTURE_OUTCOME:-}" = cancelled ]; then
  verdict=unavailable
else
  # Actions runs this step under `bash -e`: catch the exit code, or a
  # failed gate would end the step before its verdict is written.
  rc=0
  python3 scripts/cmux-next/visual-gate/visual_gate.py --json "$RUNNER_TEMP/visual-gate/report.json" \
    --summary "$GITHUB_STEP_SUMMARY" --states scripts/cmux-next/visual-gate/states "${states[@]}" || rc=$?
  case $rc in 0) verdict=pass ;; 1) verdict=fail ;; *) verdict=unavailable ;; esac
fi
blocks=false
if [ "$verdict" = fail ] && [ "$GATE_MODE" = enforce ]; then blocks=true; fi
{ echo "verdict=$verdict"; echo "blocks=$blocks"; } >> "$GITHUB_OUTPUT"
echo "visual gate: $verdict (mode $GATE_MODE: $GATE_WHY)"
case "$verdict" in
  fail) echo "::warning title=nightly-next visual gate::the stills of $BUILD_SHA failed the visual gate (mode $GATE_MODE); see the job summary and the nightly-next-visual-gate artifact" ;;
  unavailable) echo "::warning title=nightly-next visual gate::the gate could not capture or judge $BUILD_SHA; this nightly is not checked" ;;
esac
