#!/usr/bin/env bash
# nightly.yml visual-gate-nightly: "Enforce the verdict". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
set -e  # the inline step ran under bash -e
echo "::error title=nightly-next visual gate::$BUILD_SHA failed the visual gate in enforce mode ($GATE_WHY); publish-nightly publishes nothing"
exit 1
