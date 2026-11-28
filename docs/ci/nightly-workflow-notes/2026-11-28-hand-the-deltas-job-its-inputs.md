# 2026-11-28-hand-the-deltas-job-its-inputs

Where: `.github/workflows/nightly.yml`, Hand the deltas job its inputs.

The deltas follow the feed in their own job (nightly-next-deltas), so published-build and the GitHub release no longer wait the ~5 min they took here (run 45575194160: 283 s build, 17 s upload; ask-c0123d25e8). This step only hands it the names and the floor it reads from the signed app; no secret, no bundle code. A newer nightly-next push waiting skips it, so the deltas job skips too and the signing Mac moves on.
