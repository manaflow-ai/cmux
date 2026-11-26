# await-release-surface-ack: if: false

Where: the `await-release-surface-ack` job in `.github/workflows/nightly.yml`, above `if: false`.

Legacy condition retained for workflow-contract compatibility; the guarded
move now happens in promote-nightly-next and this job never waits.
if: (needs.promote-nightly-next.outputs.action == 'needs-ack' || needs.promote-nightly-next.outputs.action == 'promote') && needs.promote-nightly-next.outputs.dry_run != 'true'
