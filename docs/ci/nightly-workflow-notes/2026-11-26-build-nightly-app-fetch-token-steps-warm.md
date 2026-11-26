# build-nightly-app: FETCH_TOKEN: ${{ steps.warm-fetch-token.outputs.token || github.token }}

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `FETCH_TOKEN: ${{ steps.warm-fetch-token.outputs.token || github.token }}`.

The release App's read-only token, minted for this checkout alone (nightly-next-one's "Mint the
release App token for the warm checkout"): never the shared cmux-bot token, never the job's
GITHUB_TOKEN, never anonymous. Run 45744507889 failed on GitHub's unauthenticated per-IP limit
(raw.githubusercontent.com 429 four times, then git fetch 403). Where no step mints it
(build-nightly-app, whose environment holds no release App key) the job's own token: never anonymous.
