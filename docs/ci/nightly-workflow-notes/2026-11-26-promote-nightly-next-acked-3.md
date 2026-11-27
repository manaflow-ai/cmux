# nightly.yml: job `promote-nightly-next-acked`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Never in a cancelling group: a later request must not cancel a move. The
move is a compare-and-swap on nightly-next (one fast-forward ref update),
so a concurrent promotion is safe.
