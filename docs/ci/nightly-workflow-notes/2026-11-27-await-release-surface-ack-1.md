# 2026-11-27-await-release-surface-ack-1

Above `group: nightly-next-promote-ack${{ needs.promote-nightly-next.outputs.scan_failed == 'true' && format('-wait-{0}', github.run_id) || '' }}` (job `await-release-surface-ack`) in `.github/workflows/nightly.yml`.

A release-surface acknowledgement may wait, but it must never cancel
an older promotion that has already started. The starvation guard
coalesces newer tips after the running promotion finishes.
