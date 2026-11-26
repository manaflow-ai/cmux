# generate-nightly-deltas: environment: ${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'r

Where: the `generate-nightly-deltas` job in `.github/workflows/nightly.yml`, above `environment: ${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'release' }}`.

Delta work is deliberately downstream of the first publication. A slow
BinaryDelta process therefore cannot extend the user's wait for a full
DMG and signed appcast. The nightly-next track signs in release-next
with its own key, as build-sign-notarize-nightly does.
