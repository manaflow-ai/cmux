#!/usr/bin/env bash
# nightly.yml: "Prove the browser-data import is compiled out (cx-f58x notary test)", in
# build-nightly-app (beside the unsigned-app upload) and in both prepare-nightly-variant legs
# (when build-nightly-app did not prove this app, e.g. an unsigned resume).
#
# The cx-f58x scan reads every file of the bundle (about 105 s on a nightly Mac), so it runs in
# the background on a copy of the bundle as it is now, while later steps run (and may change
# the original). "Finish the browser-data import proof" (browser-data-proof-finish.sh) reads its
# status from a FIFO: the FIFO write blocks until that step reads it, so the status is never
# lost and nothing polls. The proof scans the whole bundle, the cmux-tui client
# build-nightly-app installs in Contents/Resources/bin included: the client carries only
# browser ids and names (#26120).
#
# The step's notes, moved from nightly.yml: in build-nightly-app it scans the bundle just
# archived (the bundle prepare restores) beside the uploads: it took 74-77 s after packaging
# on prepare's critical path (runs 41416268105, 41413478144). The finish step gates the job,
# so prepare and signing never see an unproven app; prepare scans only when this job did not
# prove it.
set -euo pipefail
state="$RUNNER_TEMP/browser-data-proof"
rm -rf "$state"
mkdir -p "$state/snapshot"
app="build-universal/Build/Products/Release/cmux.app"
cp -a "$app" "$state/snapshot/cmux.app"
mkfifo "$state/status.fifo"
(
  status=0
  scripts/ci/check-browser-data-import-absent.sh "$state/snapshot/cmux.app" || status=$?
  echo "$status" >"$state/status.fifo"
) >"$state/proof.log" 2>&1 </dev/null &
echo "browser-data import proof started on a copy of the bundle (PID $!)"
