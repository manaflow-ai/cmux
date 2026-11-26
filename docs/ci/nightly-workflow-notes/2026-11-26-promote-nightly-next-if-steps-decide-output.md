# promote-nightly-next: if: (steps.decide.outputs.action == 'promote' || steps.decide.outputs.action == 

Where: the `promote-nightly-next` job in `.github/workflows/nightly.yml`, above `if: (steps.decide.outputs.action == 'promote' || steps.decide.outputs.action == 'needs-ack') && step…`.

Legacy promote condition retained for workflow-contract compatibility.
if: steps.decide.outputs.action == 'promote' && steps.decide.outputs.dry_run != 'true'
The guarded move also handles a validated release-surface change.
