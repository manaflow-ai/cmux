# 2026-11-27-await-release-surface-ack-2

Above `promote-nightly-next-acked:` (job `await-release-surface-ack`) in `.github/workflows/nightly.yml`.

Moves nightly-next after the approval. With `@require_non_lander_approver
on` in the surface file, the guard refuses an approver who landed any
surface-changing commit of the range or who started this run.
