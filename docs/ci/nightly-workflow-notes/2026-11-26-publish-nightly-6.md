# 2026-11-26-publish-nightly-6

Above `- &x87` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

cx-f76kf: decide reads NIGHTLY_NEXT_WRITER only when the run starts, and
the HQ Linux pipeline publishes nightly-next while it is linux, so the
gate reads it again live. vars.* is fixed at run start and GITHUB_TOKEN
cannot read variables: the release App reads it (Variables: read).
A failed mint leaves the token empty, and the gate refuses.

## nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

For publish-nightly-next-github: what to publish and the release body's parts.
feed_written is false when a newer build was already on the feed.
