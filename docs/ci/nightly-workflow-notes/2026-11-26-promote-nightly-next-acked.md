# nightly.yml: job `promote-nightly-next-acked`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Legacy condition retained for workflow-contract compatibility; approval is retired.
if: needs.await-release-surface-ack.result == 'success' && needs.promote-nightly-next.outputs.action == 'needs-ack' && needs.promote-nightly-next.outputs.dry_run != 'true'
