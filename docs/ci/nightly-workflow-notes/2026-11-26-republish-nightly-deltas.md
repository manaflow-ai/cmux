# nightly.yml: job `republish-nightly-deltas`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

It holds the publish group, so a hang must not hold it for the default 6 h. nightly-next
makes no gh call here (deltas and feed go to R2) and took at most 1.3 minutes in 56 runs;
other tracks keep the default, as their release uploads may wait out the rate limit.
One-mini mode adds glaeda's capacity wait (tests/test_nightly_mini_gate_timeouts.py).
