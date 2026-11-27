# nightly.yml: job `publish-nightly`, step "Upload branch nightly artifacts (retry)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

cx-f76kf: decide reads NIGHTLY_NEXT_WRITER only when the run starts, and
the HQ Linux pipeline publishes nightly-next while it is linux, so the
gate reads it again live. vars.* is fixed at run start and GITHUB_TOKEN
cannot read variables: the release App reads it (Variables: read).
A failed mint leaves the token empty, and the gate refuses.
