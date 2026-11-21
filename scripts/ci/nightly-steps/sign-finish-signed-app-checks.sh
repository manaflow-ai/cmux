#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly: "Finish the signed-app checks". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input. An unsigned resume
# checks out an older build commit, so the step runs this script from .nightly-signing-control when that tree lacks it.
#
# The step's notes, moved from nightly.yml:
# Every Mach-O must load on the declared floor, map to its notices and
# pass the load-command check; the verify job's handoff comes from the
# same copy. A failure here fails the job, so nothing is published.
set -euo pipefail
checks=scripts/ci/signed-app-checks.sh
[ -f "$checks" ] || checks=.nightly-signing-control/scripts/ci/signed-app-checks.sh
bash "$checks" finish
