# promote-nightly-next-acked: concurrency:

Where: the `promote-nightly-next-acked` job in `.github/workflows/nightly.yml`, above `concurrency:`.

Never in a cancelling group: a later request must not cancel a move. The
move is a compare-and-swap on nightly-next (one fast-forward ref update),
so a concurrent promotion is safe.
