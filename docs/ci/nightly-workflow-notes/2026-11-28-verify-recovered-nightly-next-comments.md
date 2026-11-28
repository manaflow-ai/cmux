# nightly.yml verify-recovered-nightly-next: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `STAPLED_APP_FALLBACK_ID: ${{ needs.recover-nightly-next-notarization.outputs.stapled_app_fallback_id`:

    # Set only when the 6 h stapled-app fallback shipped the first DMG.

Above `- name: Launch smoke from a fresh home`:

    # As verify-final-dmg-nightly: a recovered build that crashes at launch is never published.
