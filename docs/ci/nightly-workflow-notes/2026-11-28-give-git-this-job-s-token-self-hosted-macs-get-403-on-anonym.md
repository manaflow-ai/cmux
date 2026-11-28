# 2026-11-28-give-git-this-job-s-token-self-hosted-macs-get-403-on-anonym

Where: `.github/workflows/nightly.yml`, Give git this job's token (self-hosted Macs get 403 on anonymous reads).

The Macs get 403 from github.com on anonymous requests. Every checkout here sets persist-credentials: false, so actions/checkout's clean of a reused partial clone (a lazy promisor fetch, before it sets up auth) and every later git fetch went out with no credential. One header job-wide: the empty entry clears any header in .git/config (two make GitHub answer 400); a step that sets its own GIT_CONFIG_COUNT still sends only its own.
