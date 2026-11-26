#!/usr/bin/env bash
# stale-part.sh PART NOTE: a nightly part that failed this run and did not hold the publish.
#
# Leo, 2026-11-25: "are we able to decouple". No single component's failure blocks the nightly: the webview
# checks, the cmux-tui client resolve, the iPhone host and the visual gate fall back to their last good
# artifact or run as a report, and the build publishes with this note. Only an app that does not launch or
# is not signed holds it (the launch smoke, signing and notarization steps still fail the job).
#
# The note is a warning annotation titled "Nightly stale part" (cmuxterm-hq's NOW reads it off the
# publishing job and shows it on the Nightly line), a step-summary line, and a line in
# $RUNNER_TEMP/nightly-stale-parts that later steps of the same job read (PART<TAB>NOTE).
# NIGHTLY_COMPONENT_GATES=block (a repository variable) restores the old hold: callers check it, not this.
set -euo pipefail
part="${1:?part}"
note="${2:?note}"
note="${note//[$'\r\n']/ }"
echo "::warning title=Nightly stale part::${part}: ${note}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "- stale part, ${part}: ${note}" >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "${RUNNER_TEMP:-}" ]; then
  printf '%s\t%s\n' "$part" "$note" >> "$RUNNER_TEMP/nightly-stale-parts"
fi
