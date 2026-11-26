# 2026-11-26-publish-release-notes-1

Above `needs: [published-build, sign-release-notes, pick-nightly-sign-runner]` (job `publish-release-notes`) in `.github/workflows/nightly.yml`.

Still publish-nightly's lock: the notes writes (notes/index.json and the
rest) have no compare-and-swap, so only that lock keeps an older build's
checked notes from landing after a newer publish. It is publish-nightly's
R2 lease, not a concurrency group: a group cancelled the older pending job
(run 41436891188). nightly-next only (if:), so no group at all.
