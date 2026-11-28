# nightly.yml: job `await-release-surface-ack`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Legacy condition retained for workflow-contract compatibility; the guarded
move now happens in promote-nightly-next and this job never waits.
if: (needs.promote-nightly-next.outputs.action == 'needs-ack' || needs.promote-nightly-next.outputs.action == 'promote') && needs.promote-nightly-next.outputs.dry_run != 'true'
