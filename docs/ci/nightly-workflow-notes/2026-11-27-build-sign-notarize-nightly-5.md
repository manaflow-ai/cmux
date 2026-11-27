# 2026-11-27-build-sign-notarize-nightly-5

Above `- *hold-the-whole-mac` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

First, before any checkout or secret: on an owned Mac this job holds the whole mini (glaeda's
exclusive class) or fails here (tests/test_ci_signing_owned_mac.py CLAIM_GATE).
