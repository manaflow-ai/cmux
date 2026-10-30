#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Start the Linux build's REF capture".
# Kept out of the workflow to keep nightly.yml under GitHub's workflow file size
# limit; the step's env: sets every input.
set -euo pipefail
if (( $(date +%s) - STARTED > 100 * 60 )); then
  echo "::notice::REF capture skipped: the job started $(( ($(date +%s) - STARTED) / 60 )) minutes ago"
  exit 0
fi
snapshot="$RUNNER_TEMP/hybrid-ref-snapshot"
rm -rf -- "$snapshot"
mkdir -p "$snapshot"
python3 -I scripts/ci/apfs_clone.py "$GITHUB_WORKSPACE" "$snapshot/src"
# A trusted worker links .spm-cache to the SourcePackages it keeps (nightly_build_state.py).
# The REF needs the package sources, so the snapshot holds a clone of what the link names.
if [ -L "$GITHUB_WORKSPACE/.spm-cache" ]; then
  packages="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$GITHUB_WORKSPACE/.spm-cache")"
  rm -f -- "$snapshot/src/.spm-cache"
  python3 -I scripts/ci/apfs_clone.py "$packages" "$snapshot/src/.spm-cache"
fi
# Its GITHUB_OUTPUT is this step's, which is closed before the capture ends.
python3 scripts/ci/background_build.py start --state "$RUNNER_TEMP/hybrid-ref-builds" capture -- \
  env -u GITHUB_OUTPUT nice -n 10 python3 -I "$snapshot/src/scripts/cmux-next/hybrid_ref_capture.py" capture \
  --log "$RUNNER_TEMP/hybrid-ref-xcodebuild.log" --workspace "$GITHUB_WORKSPACE" \
  --derived-data "$GITHUB_WORKSPACE/build-universal" --read-workspace "$snapshot/src" \
  --read-derived-data "$snapshot/src/build-universal" --sha "$BUILD_SHA" --key "$KEY" \
  --run-id "$GITHUB_RUN_ID" --lane hybrid-ref-nightly-next --out "$RUNNER_TEMP/hybrid-ref-capture" --upload \
  --deadline "$(( STARTED + 130 * 60 ))"
echo "started=true" >> "$GITHUB_OUTPUT"
