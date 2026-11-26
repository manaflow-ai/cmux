# sentry-dsyms-nightly: build-nightly-deltas:

Where: the `sentry-dsyms-nightly` job in `.github/workflows/nightly.yml`, above `build-nightly-deltas:`.

The deltas' slow part, BinaryDelta (494 s of generate-nightly-deltas' 15-min whole-Mac hold on run
42149108998), needs no key. This job builds the delta files with no secret, on a light nightly-only
runner of the nightly mini, so the keyed job below only reuses and signs them. Optional like the deltas:
a failure leaves every delta to the keyed job, which builds what it lacks as before.
