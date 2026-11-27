# 2026-11-27-build-nightly-app-4

Above `- name: Mint the glaeda read token for the unsigned restore` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

The routing App's own budget, github.token as the fallback: every workflow's github.token shares
one hourly limit, and its 403s failed this restore in sign runs 43129190893 and 43139032769.
