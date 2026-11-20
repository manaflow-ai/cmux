#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Place the light jobs on a free mini" (start) and
# "Collect the light-job placement" (finish).
#
# portable_job_placement.py waits up to 180 s for idle runners on the all-nightly
# reservation (NIGHTLY_WAIT_FOR_FLEET=1). As the job's last step that wait sat on the
# feed's critical path: 3-188 s, about 66 s on average over 16 nightly-next runs on
# 2026-11-02 (70 s in run 41485637444, 188 s in run 41482932276). `start` runs it in
# the background before the archive, so the wait overlaps the archive, the uploads and
# the browser-data proof (about 100-230 s); `finish` joins it and copies its outputs
# into this step's GITHUB_OUTPUT, so the light jobs read steps.place-light as before.
# The placement still decides only from capacity it observed live, and a job it names
# that later finds the label busy keeps the queue janitor's stall-aware failover.
# "Stop the helper builds still running" (always()) ends it if the job fails first.
set -euo pipefail
state="$RUNNER_TEMP/nightly-helper-builds"
out="$RUNNER_TEMP/light-placement"
case "${1:-}" in
  start)
    rm -rf "$out"
    mkdir -p "$out"
    : >"$out/output"
    : >"$out/summary"
    GITHUB_OUTPUT="$out/output" GITHUB_STEP_SUMMARY="$out/summary" \
      python3 scripts/ci/background_build.py start --state "$state" light-placement -- \
      python3 scripts/ci/portable_job_placement.py
    ;;
  finish)
    # The placement bounds itself (60 s of reads plus the 180 s wait); 270 s stays
    # under this step's timeout.
    python3 scripts/ci/background_build.py join --state "$state" light-placement --timeout 270
    cat "$out/output" >>"$GITHUB_OUTPUT"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$out/summary" >>"$GITHUB_STEP_SUMMARY"; fi
    ;;
  *)
    echo "usage: $0 start|finish" >&2
    exit 64
    ;;
esac
