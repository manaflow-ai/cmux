# build-nightly-app: fetch_auth=$(printf 'x-access-token:%s' "${FETCH_TOKEN:-}" | base64 | tr -d '\n'

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `fetch_auth=$(printf 'x-access-token:%s' "${FETCH_TOKEN:-}" | base64 | tr -d '\n')`.

Every read here goes out with the job's token. Anonymous, nightlies 45744507889 and
45756842046..45763487534 (2026-11-26) got 429s for git_fetch_retry.py and a 403 for the
fetch from the fleet's shared address. The header lives in this step's environment only,
never in the kept slot's git config.
