# nightly.yml: job `build-nightly-deltas`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The deltas' slow part, BinaryDelta (494 s of generate-nightly-deltas' 15-min whole-Mac hold on run
42149108998), needs no key. This job builds the delta files with no secret, on a light nightly-only
runner of the nightly mini, so the keyed job below only reuses and signs them. Optional like the deltas:
a failure leaves every delta to the keyed job, which builds what it lacks as before.
