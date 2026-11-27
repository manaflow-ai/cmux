# 2026-11-27-recover-nightly-next-notarization-2

Above `- *hold-the-whole-mac` (job `recover-nightly-next-notarization`) in `.github/workflows/nightly.yml`.

First, before any checkout or secret: on an owned Mac this job holds the whole mini (glaeda's
exclusive class) or fails here (tests/test_ci_signing_owned_mac.py CLAIM_GATE).
