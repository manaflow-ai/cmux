# 2026-11-26-generate-nightly-deltas-1

Above `environment: ${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'release' }}` (job `generate-nightly-deltas`) in `.github/workflows/nightly.yml`.

Delta work is deliberately downstream of the first publication. A slow
BinaryDelta process therefore cannot extend the user's wait for a full
DMG and signed appcast. The nightly-next track signs in release-next
with its own key, as build-sign-notarize-nightly does.
