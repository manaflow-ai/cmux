# visual-gate-nightly: visual-gate-nightly-verdict:

Where: the `visual-gate-nightly` job in `.github/workflows/nightly.yml`, above `visual-gate-nightly-verdict:`.

This Linux job records the visual verdict independently of publication. Visual coverage is
advisory so a queued or slow display runner can never hold the nightly feed.
