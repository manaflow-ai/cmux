#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly: "Start the signed-app checks (they run during notarization)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input. An unsigned resume
# checks out an older build commit, so the step runs this script from .nightly-signing-control when that tree lacks it.
#
# The step's notes, moved from nightly.yml:
# The read-only checks of the signed app and its two packages run on a
# copy of it while Apple notarizes (signed-app-checks.sh): about 2.5 min
# that used to stand between Codesign apps and the first submission. The
# notarize step changes the app in place, so the copy is taken here.
# This job holds signing secrets, so it runs no code from the bundle.
# verify-signed-nightly runs every check that executes the app, the CLI,
# the helpers or the sidecar, in a job without secrets, on this exact
# signed app and on the final DMG (#21024). Notary tests and builds held
# by NIGHTLY_NEXT_NOTARY_PAUSED (they carry the browser-data import) never
# upload a signed app and publish nothing, so they skip that job. The
# unnotarized zip is the Developer ID-signed app for teammates when
# Apple's queue is slow; the public repository never gets one from notary
# tests or paused builds, and a failed zip never blocks notarization.
set -euo pipefail
# An unsigned resume of an older tree may predate this script; its
# checks are still the tree's own (the script runs ./scripts/...).
checks=scripts/ci/signed-app-checks.sh
[ -f "$checks" ] || checks=.nightly-signing-control/scripts/ci/signed-app-checks.sh
bash "$checks" start "$CHANNEL_APP_PATH"
