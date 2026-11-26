# nightly.yml `generate-nightly-deltas`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `environment: ${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'release' }}`

Delta work is deliberately downstream of the first publication. A slow
BinaryDelta process therefore cannot extend the user's wait for a full
DMG and signed appcast. The nightly-next track signs in release-next
with its own key, as build-sign-notarize-nightly does.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' && 'glaeda-trusted-nex`

Never Blacksmith (Lawrence, 2026-10-30). A Sparkle key: placed and held whole as the legacy sign. Optional:
a failed or refused delta never fails the run or holds the feed. NIGHTLY_DELTAS=off skips them.

## 3

Above: `SPARKLE_CHANNEL: ${{ needs.published-build.outputs.track == 'nightly-next' && (vars.NIGHTLY_NEXT_DEV_RING == 'on' && 'cm`

Every item starts on the new build's ring; republish-nightly-deltas
moves the ones whose canary passed back to Nightly.

## 4

Above: `- &forget-kept-sparse-mode`

The kept clone remembers the last checkout's sparse mode. After the signer's pattern checkout
(core.sparseCheckout=true, no cone setting) git reads the cone request below as the one pattern
`scripts`, so the root .xcode-version stays out and Select Xcode fails here (runs 42819750253,
42829570644: no deltas). The warm checkout's manual sparse test runs this step.

## 5

Above: `- *github-token-for-git`

Only scripts/ (and, by cone mode, the root .xcode-version) is read from it, so it is sparse: a full
clone took 96 s of the whole-Mac hold (run 42033609306, 14:11:49-14:13:25Z).

## 6

Above: `- &checkout-the-gh-token-wrapper`

The wrapper comes from the workflow commit: the build checkout may predate it.
The publication-tooling shape test_nightly_cmux_tui_resolve.py exempts: scripts only.
