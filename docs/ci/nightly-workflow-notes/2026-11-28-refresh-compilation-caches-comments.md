# nightly.yml refresh-compilation-caches: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `refresh-compilation-caches:`:

    # The compilation-cache refreshers (nightly-compilation-cache.yml, out of this file for its size budget).

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' &&`:

    # The PR Release-build runner, so its cache is reusable; named here, where the fleet-runner guard reads it.
