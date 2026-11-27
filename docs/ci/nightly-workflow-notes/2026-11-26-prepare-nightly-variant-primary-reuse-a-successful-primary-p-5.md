# nightly.yml: job `prepare-nightly-variant-primary`, step "Reuse a successful primary preparation"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A build tree older than this workflow lacks the step scripts it added (an unsigned
resume of an older run): check out only those, from the workflow commit.
