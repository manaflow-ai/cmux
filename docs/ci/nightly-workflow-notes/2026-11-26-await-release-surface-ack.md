# nightly.yml `await-release-surface-ack`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `await-release-surface-ack:`

Legacy approval waiter retained for contract compatibility; validated moves now happen in
promote-nightly-next without an environment approval. It reads no secret and writes nothing,
so cancelling it never leaves nightly-next half-moved; the newest request wins its group.

## 2

Above: `if: false`

Legacy condition retained for workflow-contract compatibility; the guarded
move now happens in promote-nightly-next and this job never waits.
if: (needs.promote-nightly-next.outputs.action == 'needs-ack' || needs.promote-nightly-next.outputs.action == 'promote') && needs.promote-nightly-next.outputs.dry_run != 'true'

## 3

Above: `group: nightly-next-promote-ack${{ needs.promote-nightly-next.outputs.scan_failed == 'true' && format('-wait-{0}', githu`

A release-surface acknowledgement may wait, but it must never cancel
an older promotion that has already started. The starvation guard
coalesces newer tips after the running promotion finishes.
