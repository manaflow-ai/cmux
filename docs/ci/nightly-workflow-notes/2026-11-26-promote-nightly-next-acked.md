# nightly.yml `promote-nightly-next-acked`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `promote-nightly-next-acked:`

Moves nightly-next after the approval. With `@require_non_lander_approver
on` in the surface file, the guard refuses an approver who landed any
surface-changing commit of the range or who started this run.

## 2

Above: `environment: nightly-next-promote`

Holds only the release App credentials (CMUX_RELEASE_APP_*). The approval
was given to release-surface-ack on this run; guard.approvedBy() reads it.

## 3

Above: `concurrency:`

Never in a cancelling group: a later request must not cancel a move. The
move is a compare-and-swap on nightly-next (one fast-forward ref update),
so a concurrent promotion is safe.
