# build-nightly-app: Mint the glaeda read token for the unsigned restore

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `- name: Mint the glaeda read token for the unsigned restore`.

The routing App's own budget, github.token as the fallback: every workflow's github.token shares
one hourly limit, and its 403s failed this restore in sign runs 43129190893 and 43139032769.
