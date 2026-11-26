# 2026-11-26-find-nightly-next-recovery-1

Above `sign_owned: ${{ steps.sign-owned.outputs.owned }}` (job `find-nightly-next-recovery`) in `.github/workflows/nightly.yml`.

A drained owned Mac for recover-nightly-next-notarization (glaeda's exclusive class) and
verify-recovered-nightly-next, as the JSON runs-on array scripts/ci/signing_runner.py prints, or
empty. They read it only while `attempt` is the run's own attempt.
