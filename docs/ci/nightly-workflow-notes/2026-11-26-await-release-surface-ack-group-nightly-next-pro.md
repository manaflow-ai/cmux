# await-release-surface-ack: group: nightly-next-promote-ack${{ needs.promote-nightly-next.outputs.scan_faile

Where: the `await-release-surface-ack` job in `.github/workflows/nightly.yml`, above `group: nightly-next-promote-ack${{ needs.promote-nightly-next.outputs.scan_failed == 'true' && forma…`.

A release-surface acknowledgement may wait, but it must never cancel
an older promotion that has already started. The starvation guard
coalesces newer tips after the running promotion finishes.
