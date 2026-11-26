# nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

For publish-nightly-next-github: what to publish and the release body's parts.
feed_written is false when a newer build was already on the feed.
