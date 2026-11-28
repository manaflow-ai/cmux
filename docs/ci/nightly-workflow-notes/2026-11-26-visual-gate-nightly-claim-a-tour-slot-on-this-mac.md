# nightly.yml: job `visual-gate-nightly`, step "Claim a tour slot on this Mac"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The media tour's slots (scripts/ci/media_tag_lock.py): the gate builds
into a warm slot's head DerivedData and holds the slot's lock until
this job's Runner.Worker exits, so it never builds beside a tour.
