# 2026-11-26-await-release-surface-ack-1

Above `if: false` (job `await-release-surface-ack`) in `.github/workflows/nightly.yml`.

Legacy condition retained for workflow-contract compatibility; the guarded
move now happens in promote-nightly-next and this job never waits.
if: (needs.promote-nightly-next.outputs.action == 'needs-ack' || needs.promote-nightly-next.outputs.action == 'promote') && needs.promote-nightly-next.outputs.dry_run != 'true'
