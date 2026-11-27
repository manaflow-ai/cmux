# 2026-11-27-promote-nightly-next-1

Above `if: (steps.decide.outputs.action == 'promote' || steps.decide.outputs.action == 'needs-ack') && steps.decide.outputs.dry_run != 'true'` (job `promote-nightly-next`) in `.github/workflows/nightly.yml`.

Legacy promote condition retained for workflow-contract compatibility.
if: steps.decide.outputs.action == 'promote' && steps.decide.outputs.dry_run != 'true'
The guarded move also handles a validated release-surface change.
