# promote-nightly-next-acked: if: false

Where: the `promote-nightly-next-acked` job in `.github/workflows/nightly.yml`, above `if: false`.

Legacy condition retained for workflow-contract compatibility; approval is retired.
if: needs.await-release-surface-ack.result == 'success' && needs.promote-nightly-next.outputs.action == 'needs-ack' && needs.promote-nightly-next.outputs.dry_run != 'true'
