# 2026-11-27-promote-nightly-next-acked-1

Above `if: false` (job `promote-nightly-next-acked`) in `.github/workflows/nightly.yml`.

Legacy condition retained for workflow-contract compatibility; approval is retired.
if: needs.await-release-surface-ack.result == 'success' && needs.promote-nightly-next.outputs.action == 'needs-ack' && needs.promote-nightly-next.outputs.dry_run != 'true'
