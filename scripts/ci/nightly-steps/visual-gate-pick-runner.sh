#!/usr/bin/env bash
# nightly.yml route-visual-gate-nightly: "Pick an idle owned session runner". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# The media tour's runner: an owned Mac's session runner (else its gui
# runner), the one that holds the logged-in console session the app
# draws in, and only one that is idle now (--idle-now). A self-hosted job
# queued for a busy runner can wait a day, and publish-nightly waits on
# this one, so with none idle the gate is skipped. Workflows never name
# an owned label (tests/test_ci_self_hosted_guard.sh); it arrives as
# this output.
set -euo pipefail
python3 scripts/ci/cmux_next_media_runner.py --same-repo true --idle-now | tee "$RUNNER_TEMP/pick.out"
if ! grep -q '^runs_on=.' "$RUNNER_TEMP/pick.out"; then
  reason="$(sed -n 's/^reason=//p' "$RUNNER_TEMP/pick.out")"
  echo "verdict=unavailable" >> "$GITHUB_OUTPUT"
  echo "::warning title=nightly-next visual gate::skipped, verdict unavailable: $reason; $BUILD_SHA is not checked"
  printf '## Nightly visual gate\n\nSkipped for `%s`, verdict `unavailable`: %s. This nightly is not checked and publishes as usual.\n' \
    "$BUILD_SHA" "$reason" >> "$GITHUB_STEP_SUMMARY"
fi
