# 2026-11-27-build-nightly-app-1

Above `concurrency:` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

One build slot per run: a newer push builds beside an older one and never
replaces it (a shared slot evicted waiting builds, 2026-10-19). publish-nightly's
recheck refuses a build no newer than both feeds.
