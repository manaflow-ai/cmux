# build-nightly-app: if [ -z "$source" ] && [ -z "${FETCH_TOKEN:-}" ]; then

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `if [ -z "$source" ] && [ -z "${FETCH_TOKEN:-}" ]; then`.

The mirror never got the commit: fetch only that commit from GitHub, authenticated with the release App's
token (the job's own where none is minted), with a bounded backoff on a 429 or 403. Before each try
the mirror is read again, so a pass of the host's fetcher that lands meanwhile wins.
