# await-release-surface-ack: promote-nightly-next-acked:

Where: the `await-release-surface-ack` job in `.github/workflows/nightly.yml`, above `promote-nightly-next-acked:`.

Moves nightly-next after the approval. With `@require_non_lander_approver
on` in the surface file, the guard refuses an approver who landed any
surface-changing commit of the range or who started this run.
