# build-sign-notarize-nightly: *hold-the-whole-mac

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `- *hold-the-whole-mac`.

First, before any checkout or secret: on an owned Mac this job holds the whole mini (glaeda's
exclusive class) or fails here (tests/test_ci_signing_owned_mac.py CLAIM_GATE).
