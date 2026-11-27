# 2026-11-27-promote-nightly-next-acked-3

Above `concurrency:` (job `promote-nightly-next-acked`) in `.github/workflows/nightly.yml`.

Never in a cancelling group: a later request must not cancel a move. The
move is a compare-and-swap on nightly-next (one fast-forward ref update),
so a concurrent promotion is safe.
