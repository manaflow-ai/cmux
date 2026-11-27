# 2026-11-27-visual-gate-nightly-3

Above `visual-gate-nightly-verdict:` (job `visual-gate-nightly`) in `.github/workflows/nightly.yml`.

This Linux job records the visual verdict independently of publication. Visual coverage is
advisory so a queued or slow display runner can never hold the nightly feed.
