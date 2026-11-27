# 2026-11-26-build-sign-notarize-nightly-5

Above `SPARKLE_CHANNEL: ${{ needs.decide.outputs.track == 'nightly-next' && (vars.NIGHTLY_NEXT_DEV_RING == 'on' && 'cmux-next-dev' || 'cmux-next') || '' }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

cmux-next items carry a release-ring sparkle:channel, which only
cmux-next builds allow; every other build ignores them. With
NIGHTLY_NEXT_DEV_RING=on a new build starts on Dev (cmux-next-dev)
and moves to Nightly (cmux-next) on a canary pass
(scripts/ci/nightly_next_ring.py, nightly-next-verdict.yml).

## nightly.yml: job `build-sign-notarize-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

One universal Xcode build feeds every variant: the thin variants are cut
from it with lipo, so each user downloads only their architecture.
