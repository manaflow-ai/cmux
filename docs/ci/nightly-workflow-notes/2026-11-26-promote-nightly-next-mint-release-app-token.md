# nightly.yml: job `promote-nightly-next`, step "Mint release App token"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Legacy promote condition retained for workflow-contract compatibility.
if: steps.decide.outputs.action == 'promote' && steps.decide.outputs.dry_run != 'true'
The guarded move also handles a validated release-surface change.
