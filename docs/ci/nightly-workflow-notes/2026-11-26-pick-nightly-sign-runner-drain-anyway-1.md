# pick-nightly-sign-runner: DRAIN_ANYWAY: "1"

Where: the `pick-nightly-sign-runner` job in `.github/workflows/nightly.yml`, above `DRAIN_ANYWAY: "1"`.

Drain the mini that frees up soonest even past the 2 min horizon, never Blacksmith first
(signing_runner.py DRAIN_ANYWAY; Leo, 2026-10-30).
