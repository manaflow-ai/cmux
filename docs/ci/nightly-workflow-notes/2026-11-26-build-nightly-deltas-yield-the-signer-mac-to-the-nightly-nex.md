# nightly.yml: job `build-nightly-deltas`, step "Yield the signer Mac to the nightly-next build loop"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Before the keyed job asks for the signer Mac; scripts/ci/nightly_deltas_yield.py. Two signers (ultra1, cmux15)
do not wait for the loop (a build may still wait; see the script); one-mini mode or NIGHTLY_NEXT_SIGNERS=1 waits.
