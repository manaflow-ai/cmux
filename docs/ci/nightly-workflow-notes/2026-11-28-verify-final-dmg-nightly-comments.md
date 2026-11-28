# nightly.yml verify-final-dmg-nightly: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `smoked_in_job: ${{ steps.own-smoke.outcome == 'success' }}`:

    # 'true' only when this job's own launch smoke passed.

Above `STAPLED_APP_FALLBACK_ID: ${{ needs.build-sign-notarize-nightly.outputs.stapled_app_fallback_id }}`:

    # Set only when the 6 h stapled-app fallback shipped the first DMG.

Above `CMUX_CI_XCODE_APP: ${{ needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && needs`:

    # An owned Mac has the PR lane's Xcode pin (as DEV's verify); Blacksmith the macOS 26 one.

Above `- &checkout-publication-tooling-a`:

    # Publication tooling from this workflow's own commit (see publish-nightly).
