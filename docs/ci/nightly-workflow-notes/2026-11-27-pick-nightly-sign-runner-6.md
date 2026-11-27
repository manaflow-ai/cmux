# 2026-11-27-pick-nightly-sign-runner-6

Above `DRAIN_ANYWAY: "1"` (job `pick-nightly-sign-runner`) in `.github/workflows/nightly.yml`.

Drain the mini that frees up soonest even past the 2 min horizon, never Blacksmith first
(signing_runner.py DRAIN_ANYWAY; Leo, 2026-10-30).
