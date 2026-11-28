# nightly.yml verify-signed-nightly: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `if: "!cancelled() && needs.build-sign-notarize-nightly.result == 'success' && needs.decide.outputs.n`:

    # The macOS signer's app.

Above `permissions:`:

    # actions:read lets a sign stage's parallel download of the signed app resolve the blob URL.

Above `STAPLED_APP_FALLBACK_ID: ${{ needs.build-sign-notarize-nightly.outputs.stapled_app_fallback_id }}`:

    # Set only when the 6 h stapled-app fallback shipped the first DMG.

Above `CMUX_CI_XCODE_APP: ${{ needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && needs`:

    # An owned Mac has the PR lane's Xcode pin (as DEV's verify); Blacksmith the macOS 26 one.

Above `- *legacy-route-shared-5`:

    # nightly-next's license check reads ghostty-next/build.zig.zon.

Above `- &older-tree-step-scripts-plain`:

    # The same restore for a job with no prepare reuse step: only the tree's age decides.
