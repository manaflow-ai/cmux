#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Finish the Linux build's REF capture".
# Kept out of the workflow to keep nightly.yml under GitHub's workflow file size
# limit; the step's env: sets every input.
set -uo pipefail
state="$RUNNER_TEMP/hybrid-ref-builds"
budget=$(( 130 * 60 - ($(date +%s) - STARTED) ))
(( budget > 240 )) && budget=240
status=1
if (( budget > 0 )); then
  python3 scripts/ci/background_build.py join --state "$state" capture --timeout "$budget" && status=0
fi
if (( status != 0 )); then
  echo "::notice::REF capture stopped: not done within its budget, or failed"
  python3 scripts/ci/background_build.py stop --state "$state"
fi
rm -rf -- "$RUNNER_TEMP/hybrid-ref-snapshot" "$RUNNER_TEMP/hybrid-ref-capture/packs"
manifest="$RUNNER_TEMP/hybrid-ref-capture/manifest.json"
if (( status == 0 )) && [ -f "$manifest" ]; then
  complete="$(python3 -c 'import json, sys; print(str(json.load(open(sys.argv[1]))["complete"]).lower())' "$manifest")"
  printf 'manifest=%s\ncomplete=%s\n' "$manifest" "$complete" >> "$GITHUB_OUTPUT"
fi
