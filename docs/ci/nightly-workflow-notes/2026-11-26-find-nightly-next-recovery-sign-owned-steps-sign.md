# find-nightly-next-recovery: sign_owned: ${{ steps.sign-owned.outputs.owned }}

Where: the `find-nightly-next-recovery` job in `.github/workflows/nightly.yml`, above `sign_owned: ${{ steps.sign-owned.outputs.owned }}`.

A drained owned Mac for recover-nightly-next-notarization (glaeda's exclusive class) and
verify-recovered-nightly-next, as the JSON runs-on array scripts/ci/signing_runner.py prints, or
empty. They read it only while `attempt` is the run's own attempt.
