# nightly.yml: job `await-release-surface-ack`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Legacy approval waiter retained for contract compatibility; validated moves now happen in
promote-nightly-next without an environment approval. It reads no secret and writes nothing,
so cancelling it never leaves nightly-next half-moved; the newest request wins its group.
