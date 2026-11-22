#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Record prepared app digest". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# nightly-sign.yml (run from main) reads this annotation of this job
# through the checks API and refuses a tarball with another sha256.
set -euo pipefail
digest="$(shasum -a 256 prepared-app-handoff/cmux-prepared-app.tar.gz | awk '{print $1}')"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "no sha256 for the prepared app" >&2; exit 1; }
echo "::notice title=nightly-prepared-app::variant=${NIGHTLY_VARIANT} artifact=${PREPARED_APP_ARTIFACT} sha256=${digest} publish=${NIGHTLY_SHOULD_PUBLISH} fast=${NIGHTLY_FAST_BUILD}"
