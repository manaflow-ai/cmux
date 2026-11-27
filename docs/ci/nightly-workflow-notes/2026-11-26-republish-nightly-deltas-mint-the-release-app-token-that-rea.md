# nightly.yml: job `republish-nightly-deltas`, step "Mint the release App token that reads the Dev ring switch"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The release App with every permission it has (Variables: read); the job's other App token
is contents-only. A failed mint leaves it empty, and the ring reads off.
